import Foundation

public enum WAV {
    /// 16-bit PCM mono WAV, the format both whisper.cpp and the Whisper APIs read.
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                 // fmt chunk size
        append(UInt16(1))                  // PCM
        append(UInt16(1))                  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))     // byte rate
        append(UInt16(2))                  // block align
        append(UInt16(16))                 // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            let clamped = max(-1, min(1, s.isFinite ? s : 0))
            pcm[i] = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

public enum AudioLevel {
    /// Maps an RMS value to 0...1 on a -50 dB ... -10 dB scale, for the level meter.
    public static func meter(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 50) / 40))
    }
}
