import AVFoundation
import UtterCore

enum RecorderError: LocalizedError {
    case noInputDevice
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone found"
        case .unsupportedFormat: return "Microphone format not supported"
        }
    }
}

/// Captures the default input device as 16 kHz mono Float32, which is what
/// Whisper wants. A fresh AVAudioEngine per recording means a headset that was
/// plugged in or unplugged since last time is picked up without special handling.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate = 16_000

    /// Called on the audio thread with each buffer's RMS level.
    var onLevel: (@Sendable (Float) -> Void)?

    private var engine: AVAudioEngine?
    private let samples = Locked<[Float]>([])
    private let peak = Locked<Float>(0)

    var isRecording: Bool { engine != nil }

    func start() throws {
        cancel()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate),
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecorderError.unsupportedFormat
        }

        samples.value = []
        samples.mutate { $0.reserveCapacity(Self.sampleRate * 30) }
        peak.value = 0

        let samples = self.samples
        let peak = self.peak
        let onLevel = self.onLevel

        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            let ratio = outputFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

            let consumed = Locked(false)
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                if consumed.value {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed.value = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let channel = converted.floatChannelData?[0] else { return }

            let count = Int(converted.frameLength)
            guard count > 0 else { return }
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            var sumOfSquares: Float = 0
            for s in chunk { sumOfSquares += s * s }
            let rms = (sumOfSquares / Float(count)).squareRoot()

            samples.mutate { $0.append(contentsOf: chunk) }
            peak.mutate { if rms > $0 { $0 = rms } }
            onLevel?(rms)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    /// Stops and returns what was captured.
    func stop() -> Recording {
        teardown()
        let recording = Recording(samples: samples.value, sampleRate: Self.sampleRate, peakRMS: peak.value)
        samples.value = []
        return recording
    }

    /// Stops and throws the audio away.
    func cancel() {
        teardown()
        samples.value = []
        peak.value = 0
    }

    private func teardown() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
