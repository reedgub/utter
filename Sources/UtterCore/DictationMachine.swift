import Foundation

public struct DictationTiming: Equatable, Sendable {
    /// A press shorter than this is a tap; at or above it, a hold.
    public var tapThreshold: TimeInterval
    /// How long after a short tap a second press still counts as a double-tap.
    public var doubleTapWindow: TimeInterval
    /// Hard cap on any recording, hold or hands-free.
    public var maxDuration: TimeInterval

    public init(tapThreshold: TimeInterval = 0.25, doubleTapWindow: TimeInterval = 0.35, maxDuration: TimeInterval = 300) {
        self.tapThreshold = tapThreshold
        self.doubleTapWindow = doubleTapWindow
        self.maxDuration = maxDuration
    }
}

public enum RecordingMode: Equatable, Sendable {
    case hold, handsFree
}

public enum DictationState: Equatable, Sendable {
    case idle
    /// Hotkey just went down. Recording has started (so no first syllable is lost)
    /// but it is not yet known whether this is a hold or the first of two taps.
    case pressed(since: TimeInterval)
    /// Held past the tap threshold: hold-to-talk.
    case holding(since: TimeInterval)
    /// Released after a short tap; still recording while we wait for a second tap.
    case awaitingSecondTap(since: TimeInterval)
    /// Double-tapped. `ignoreNextRelease` swallows the release of the second tap.
    case handsFree(since: TimeInterval, ignoreNextRelease: Bool)
    /// Recording finished; transcribing, cleaning up and inserting.
    case processing

    public var isRecording: Bool {
        switch self {
        case .pressed, .holding, .awaitingSecondTap, .handsFree: return true
        case .idle, .processing: return false
        }
    }

    public var recordingSince: TimeInterval? {
        switch self {
        case .pressed(let s), .holding(let s), .awaitingSecondTap(let s), .handsFree(let s, _): return s
        case .idle, .processing: return nil
        }
    }
}

public enum TimerKind: Hashable, Sendable {
    case holdDecision, doubleTapWindow, maxDuration
}

public enum DictationEvent: Equatable, Sendable {
    case hotkeyPressed(at: TimeInterval)
    case hotkeyReleased(at: TimeInterval)
    case interrupted
    case escape
    case timerFired(TimerKind, token: Int)
    case processingFinished
    /// Disable, settings reload or a failure: drop whatever is happening.
    case reset
}

public enum DictationEffect: Equatable, Sendable {
    case startRecording
    case finishRecording(mode: RecordingMode, autoStopped: Bool)
    case discardRecording
    case cancelProcessing
    case schedule(TimerKind, after: TimeInterval, token: Int)
}

/// The whole hold / double-tap / hands-free / Esc behaviour as a pure reducer:
/// events in, effects out. Timers are requested as effects and come back as
/// events carrying a token, so a stale timer can never act on a newer session.
public struct DictationMachine: Sendable {
    public private(set) var state: DictationState = .idle
    public var timing: DictationTiming

    private var liveTokens: [TimerKind: Int] = [:]
    private var nextToken = 1

    public init(timing: DictationTiming = DictationTiming()) {
        self.timing = timing
    }

    public mutating func handle(_ event: DictationEvent) -> [DictationEffect] {
        switch (state, event) {

        // Start: record immediately, decide tap vs hold later.
        case (.idle, .hotkeyPressed(let t)):
            state = .pressed(since: t)
            return [
                .startRecording,
                schedule(.holdDecision, after: timing.tapThreshold),
                schedule(.maxDuration, after: timing.maxDuration),
            ]

        case (.pressed(let s), .timerFired(.holdDecision, let token)) where isLive(.holdDecision, token):
            liveTokens[.holdDecision] = nil
            state = .holding(since: s)
            return []

        // Released. The timestamp decides, so a late holdDecision timer
        // cannot turn a real hold into a tap.
        case (.pressed(let s), .hotkeyReleased(let t)):
            liveTokens[.holdDecision] = nil
            if t - s >= timing.tapThreshold {
                return finish(.hold, autoStopped: false)
            }
            state = .awaitingSecondTap(since: s)
            return [schedule(.doubleTapWindow, after: timing.doubleTapWindow)]

        case (.holding, .hotkeyReleased):
            return finish(.hold, autoStopped: false)

        // Second tap in time: hands-free. Keeps the audio from the first tap.
        case (.awaitingSecondTap(let s), .hotkeyPressed):
            liveTokens[.doubleTapWindow] = nil
            state = .handsFree(since: s, ignoreNextRelease: true)
            return []

        // A single short tap: nothing worth transcribing.
        case (.awaitingSecondTap, .timerFired(.doubleTapWindow, let token)) where isLive(.doubleTapWindow, token):
            return toIdle([.discardRecording])

        case (.handsFree(let s, true), .hotkeyReleased):
            state = .handsFree(since: s, ignoreNextRelease: false)
            return []

        // One more tap ends hands-free. Acting on the press feels instant.
        case (.handsFree, .hotkeyPressed):
            return finish(.handsFree, autoStopped: false)

        // The safety cap, for hands-free and for a hold whose release was missed.
        case (.pressed, .timerFired(.maxDuration, let token)) where isLive(.maxDuration, token),
             (.holding, .timerFired(.maxDuration, let token)) where isLive(.maxDuration, token):
            return finish(.hold, autoStopped: true)
        case (.handsFree, .timerFired(.maxDuration, let token)) where isLive(.maxDuration, token):
            return finish(.handsFree, autoStopped: true)
        case (.awaitingSecondTap, .timerFired(.maxDuration, let token)) where isLive(.maxDuration, token):
            return toIdle([.discardRecording])

        // fn+Delete, right-⌘+C and friends: a shortcut, not dictation.
        // Hands-free ignores typing so you can keep working while it listens.
        case (.pressed, .interrupted), (.holding, .interrupted), (.awaitingSecondTap, .interrupted):
            return toIdle([.discardRecording])

        case (.pressed, .escape), (.holding, .escape), (.awaitingSecondTap, .escape), (.handsFree, .escape):
            return toIdle([.discardRecording])

        case (.processing, .escape):
            return toIdle([.cancelProcessing])

        case (.processing, .processingFinished):
            return toIdle([])

        case (_, .reset):
            if state.isRecording { return toIdle([.discardRecording]) }
            if state == .processing { return toIdle([.cancelProcessing]) }
            return toIdle([])

        default:
            return []
        }
    }

    private func isLive(_ kind: TimerKind, _ token: Int) -> Bool {
        liveTokens[kind] == token
    }

    private mutating func schedule(_ kind: TimerKind, after delay: TimeInterval) -> DictationEffect {
        let token = nextToken
        nextToken += 1
        liveTokens[kind] = token
        return .schedule(kind, after: delay, token: token)
    }

    private mutating func finish(_ mode: RecordingMode, autoStopped: Bool) -> [DictationEffect] {
        liveTokens.removeAll()
        state = .processing
        return [.finishRecording(mode: mode, autoStopped: autoStopped)]
    }

    private mutating func toIdle(_ effects: [DictationEffect]) -> [DictationEffect] {
        liveTokens.removeAll()
        state = .idle
        return effects
    }
}
