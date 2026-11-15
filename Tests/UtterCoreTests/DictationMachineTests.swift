import XCTest
@testable import UtterCore

final class DictationMachineTests: XCTestCase {
    private let timing = DictationTiming(tapThreshold: 0.25, doubleTapWindow: 0.35, maxDuration: 300)

    private func token(_ kind: TimerKind, in effects: [DictationEffect]) -> Int? {
        for case let .schedule(k, _, t) in effects where k == kind { return t }
        return nil
    }

    func testHoldToTalk() {
        var m = DictationMachine(timing: timing)
        let start = m.handle(.hotkeyPressed(at: 10))
        XCTAssertEqual(start.first, .startRecording)
        XCTAssertEqual(m.state, .pressed(since: 10))

        let hold = token(.holdDecision, in: start)!
        XCTAssertEqual(m.handle(.timerFired(.holdDecision, token: hold)), [])
        XCTAssertEqual(m.state, .holding(since: 10))

        XCTAssertEqual(m.handle(.hotkeyReleased(at: 12)), [.finishRecording(mode: .hold, autoStopped: false)])
        XCTAssertEqual(m.state, .processing)

        XCTAssertEqual(m.handle(.processingFinished), [])
        XCTAssertEqual(m.state, .idle)
    }

    func testHoldIsJudgedByTimestampEvenIfTimerIsLate() {
        var m = DictationMachine(timing: timing)
        _ = m.handle(.hotkeyPressed(at: 0))
        // Release 0.4 s later, before the hold-decision timer was delivered.
        XCTAssertEqual(m.handle(.hotkeyReleased(at: 0.4)), [.finishRecording(mode: .hold, autoStopped: false)])
    }

    func testSingleShortTapIsDiscarded() {
        var m = DictationMachine(timing: timing)
        _ = m.handle(.hotkeyPressed(at: 0))
        let release = m.handle(.hotkeyReleased(at: 0.1))
        XCTAssertEqual(m.state, .awaitingSecondTap(since: 0))
        let window = token(.doubleTapWindow, in: release)!
        XCTAssertEqual(m.handle(.timerFired(.doubleTapWindow, token: window)), [.discardRecording])
        XCTAssertEqual(m.state, .idle)
    }

    func testDoubleTapStartsHandsFreeAndNextTapFinishes() {
        var m = DictationMachine(timing: timing)
        _ = m.handle(.hotkeyPressed(at: 0))
        let release = m.handle(.hotkeyReleased(at: 0.08))
        let window = token(.doubleTapWindow, in: release)!

        XCTAssertEqual(m.handle(.hotkeyPressed(at: 0.2)), [])
        XCTAssertEqual(m.state, .handsFree(since: 0, ignoreNextRelease: true))
        // The second tap's release does not stop anything.
        XCTAssertEqual(m.handle(.hotkeyReleased(at: 0.27)), [])
        XCTAssertEqual(m.state, .handsFree(since: 0, ignoreNextRelease: false))
        // The stale double-tap timer must not discard the session.
        XCTAssertEqual(m.handle(.timerFired(.doubleTapWindow, token: window)), [])

        // Typing during hands-free is allowed.
        XCTAssertEqual(m.handle(.interrupted), [])

        XCTAssertEqual(m.handle(.hotkeyPressed(at: 30)), [.finishRecording(mode: .handsFree, autoStopped: false)])
        XCTAssertEqual(m.state, .processing)
        // Its release is ignored while processing.
        XCTAssertEqual(m.handle(.hotkeyReleased(at: 30.1)), [])
    }

    func testHandsFreeAutoStopsAtLimit() {
        var m = DictationMachine(timing: timing)
        let start = m.handle(.hotkeyPressed(at: 0))
        let max = token(.maxDuration, in: start)!
        _ = m.handle(.hotkeyReleased(at: 0.05))
        _ = m.handle(.hotkeyPressed(at: 0.15))
        _ = m.handle(.hotkeyReleased(at: 0.2))
        XCTAssertEqual(m.handle(.timerFired(.maxDuration, token: max)), [.finishRecording(mode: .handsFree, autoStopped: true)])
        XCTAssertEqual(m.state, .processing)
    }

    func testStuckHoldAlsoAutoStops() {
        var m = DictationMachine(timing: timing)
        let start = m.handle(.hotkeyPressed(at: 0))
        _ = m.handle(.timerFired(.holdDecision, token: token(.holdDecision, in: start)!))
        XCTAssertEqual(m.handle(.timerFired(.maxDuration, token: token(.maxDuration, in: start)!)),
                       [.finishRecording(mode: .hold, autoStopped: true)])
    }

    func testTimerFromPreviousSessionIsIgnored() {
        var m = DictationMachine(timing: timing)
        let first = m.handle(.hotkeyPressed(at: 0))
        let oldMax = token(.maxDuration, in: first)!
        _ = m.handle(.hotkeyReleased(at: 1))
        _ = m.handle(.processingFinished)

        _ = m.handle(.hotkeyPressed(at: 100))
        _ = m.handle(.hotkeyReleased(at: 100.05))
        _ = m.handle(.hotkeyPressed(at: 100.1))
        XCTAssertEqual(m.handle(.timerFired(.maxDuration, token: oldMax)), [])
        if case .handsFree = m.state {} else { XCTFail("expected hands-free, got \(m.state)") }
    }

    func testEscapeCancelsRecordingInEveryMode() {
        for setup in [0, 1, 2, 3] {
            var m = DictationMachine(timing: timing)
            let start = m.handle(.hotkeyPressed(at: 0))
            switch setup {
            case 1: _ = m.handle(.timerFired(.holdDecision, token: token(.holdDecision, in: start)!))
            case 2: _ = m.handle(.hotkeyReleased(at: 0.1))
            case 3: _ = m.handle(.hotkeyReleased(at: 0.1)); _ = m.handle(.hotkeyPressed(at: 0.2))
            default: break
            }
            XCTAssertEqual(m.handle(.escape), [.discardRecording], "setup \(setup)")
            XCTAssertEqual(m.state, .idle)
        }
    }

    func testEscapeKillsTranscription() {
        var m = DictationMachine(timing: timing)
        _ = m.handle(.hotkeyPressed(at: 0))
        _ = m.handle(.hotkeyReleased(at: 1))
        XCTAssertEqual(m.handle(.escape), [.cancelProcessing])
        XCTAssertEqual(m.state, .idle)
        // A late finish from the cancelled job changes nothing.
        XCTAssertEqual(m.handle(.processingFinished), [])
    }

    func testEscapeWhileIdleDoesNothing() {
        var m = DictationMachine(timing: timing)
        XCTAssertEqual(m.handle(.escape), [])
        XCTAssertEqual(m.state, .idle)
    }

    func testShortcutWithHotkeyHeldDiscards() {
        var m = DictationMachine(timing: timing)
        _ = m.handle(.hotkeyPressed(at: 0))
        XCTAssertEqual(m.handle(.interrupted), [.discardRecording])
        XCTAssertEqual(m.state, .idle)
        // Releasing fn after fn+Delete must not start anything.
        XCTAssertEqual(m.handle(.hotkeyReleased(at: 0.5)), [])
    }

    func testPressWhileProcessingIsIgnored() {
        var m = DictationMachine(timing: timing)
        _ = m.handle(.hotkeyPressed(at: 0))
        _ = m.handle(.hotkeyReleased(at: 1))
        XCTAssertEqual(m.handle(.hotkeyPressed(at: 1.5)), [])
        XCTAssertEqual(m.state, .processing)
    }

    func testReset() {
        var m = DictationMachine(timing: timing)
        _ = m.handle(.hotkeyPressed(at: 0))
        XCTAssertEqual(m.handle(.reset), [.discardRecording])
        _ = m.handle(.hotkeyPressed(at: 5))
        _ = m.handle(.hotkeyReleased(at: 6))
        XCTAssertEqual(m.handle(.reset), [.cancelProcessing])
        XCTAssertEqual(m.handle(.reset), [])
    }
}
