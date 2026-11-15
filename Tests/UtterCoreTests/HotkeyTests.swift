import XCTest
@testable import UtterCore

final class HotkeyParseTests: XCTestCase {
    func testModifierKeys() throws {
        XCTAssertEqual(try Hotkey.parse("fn"), .modifier(.fn))
        XCTAssertEqual(try Hotkey.parse("Globe"), .modifier(.fn))
        XCTAssertEqual(try Hotkey.parse("right_option"), .modifier(.rightOption))
        XCTAssertEqual(try Hotkey.parse("right-cmd"), .modifier(.rightCommand))
        XCTAssertEqual(try Hotkey.parse("left_ctrl"), .modifier(.leftControl))
        XCTAssertEqual(try Hotkey.parse("rshift"), .modifier(.rightShift))
    }

    func testChords() throws {
        guard case .chord(let code, let mods, let display) = try Hotkey.parse("ctrl+option+space") else {
            return XCTFail("expected chord")
        }
        XCTAssertEqual(code, 49)
        XCTAssertEqual(mods, [.control, .option])
        XCTAssertEqual(display, "⌃⌥Space")

        guard case .chord(let d, let dMods, _) = try Hotkey.parse("Cmd + Shift + D") else { return XCTFail() }
        XCTAssertEqual(d, 2)
        XCTAssertEqual(dMods, [.command, .shift])

        guard case .chord(let f5, let none, _) = try Hotkey.parse("f5") else { return XCTFail() }
        XCTAssertEqual(f5, 96)
        XCTAssertEqual(none, [])

        guard case .chord(let minus, _, _) = try Hotkey.parse("ctrl+-") else { return XCTFail() }
        XCTAssertEqual(minus, 27)

        guard case .chord(let pageUp, _, _) = try Hotkey.parse("ctrl+page-up") else { return XCTFail() }
        XCTAssertEqual(pageUp, 116)
    }

    func testRejectsUnusableHotkeys() {
        XCTAssertThrowsError(try Hotkey.parse(""))
        XCTAssertThrowsError(try Hotkey.parse("option"))          // which side?
        XCTAssertThrowsError(try Hotkey.parse("d"))               // would eat a letter
        XCTAssertThrowsError(try Hotkey.parse("ctrl+escape"))     // reserved for cancel
        XCTAssertThrowsError(try Hotkey.parse("hyper+d"))
        XCTAssertThrowsError(try Hotkey.parse("ctrl+banana"))
        XCTAssertThrowsError(try Hotkey.parse("ctrl++"))
    }
}

final class HotkeyDetectorTests: XCTestCase {
    func testFnPressAndRelease() {
        var d = HotkeyDetector(hotkey: .modifier(.fn))
        XCTAssertEqual(d.handle(.flagsChanged(keyCode: 63, flags: .fn)), DetectorOutput(signal: .pressed, swallow: false))
        XCTAssertEqual(d.handle(.flagsChanged(keyCode: 63, flags: [])), DetectorOutput(signal: .released, swallow: false))
    }

    func testArrowKeysCarryFnFlagButAreNotTheHotkey() {
        var d = HotkeyDetector(hotkey: .modifier(.fn))
        XCTAssertEqual(d.handle(.keyDown(keyCode: 126, flags: .fn, isRepeat: false)), .pass)
        XCTAssertFalse(d.isDown)
    }

    func testOtherKeyWhileFnHeldInterrupts() {
        var d = HotkeyDetector(hotkey: .modifier(.fn))
        _ = d.handle(.flagsChanged(keyCode: 63, flags: .fn))
        XCTAssertEqual(d.handle(.keyDown(keyCode: 51, flags: .fn, isRepeat: false)).signal, .interrupted)
    }

    func testRightOptionIgnoresLeftOption() {
        var d = HotkeyDetector(hotkey: .modifier(.rightOption))
        XCTAssertEqual(d.handle(.flagsChanged(keyCode: 58, flags: [.option, .leftOption])), .pass)
        XCTAssertEqual(d.handle(.flagsChanged(keyCode: 61, flags: [.option, .leftOption, .rightOption])).signal, .pressed)
        // Left option released while right is still held: still down.
        XCTAssertEqual(d.handle(.flagsChanged(keyCode: 58, flags: [.option, .rightOption])), .pass)
        XCTAssertEqual(d.handle(.flagsChanged(keyCode: 61, flags: [])).signal, .released)
    }

    func testMissedReleaseIsCaughtOnNextFlagsChange() {
        var d = HotkeyDetector(hotkey: .modifier(.fn))
        _ = d.handle(.flagsChanged(keyCode: 63, flags: .fn))
        // fn's own release was lost; a later shift press shows fn is no longer held.
        XCTAssertEqual(d.handle(.flagsChanged(keyCode: 56, flags: [.shift, .leftShift])).signal, .released)
    }

    func testEscapeIsReportedButNeverSwallowed() {
        var d = HotkeyDetector(hotkey: .modifier(.fn))
        XCTAssertEqual(d.handle(.keyDown(keyCode: 53, flags: [], isRepeat: false)), DetectorOutput(signal: .escape, swallow: false))
        var chord = HotkeyDetector(hotkey: try! Hotkey.parse("ctrl+option+space"))
        XCTAssertEqual(chord.handle(.keyDown(keyCode: 53, flags: [], isRepeat: false)), DetectorOutput(signal: .escape, swallow: false))
    }

    func testChordIsSwallowedIncludingRepeatsAndKeyUp() {
        var d = HotkeyDetector(hotkey: try! Hotkey.parse("ctrl+option+space"))
        let flags: EventFlags = [.control, .option, .leftControl, .leftOption]
        XCTAssertEqual(d.handle(.keyDown(keyCode: 49, flags: flags, isRepeat: false)), DetectorOutput(signal: .pressed, swallow: true))
        XCTAssertEqual(d.handle(.keyDown(keyCode: 49, flags: flags, isRepeat: true)), DetectorOutput(signal: nil, swallow: true))
        // Modifiers let go first: the space key-up still ends it and is swallowed.
        XCTAssertEqual(d.handle(.keyUp(keyCode: 49, flags: [])), DetectorOutput(signal: .released, swallow: true))
    }

    func testChordNeedsExactModifiers() {
        var d = HotkeyDetector(hotkey: try! Hotkey.parse("ctrl+option+space"))
        XCTAssertEqual(d.handle(.keyDown(keyCode: 49, flags: [], isRepeat: false)), .pass)
        XCTAssertEqual(d.handle(.keyDown(keyCode: 49, flags: [.control, .option, .command], isRepeat: false)), .pass)
        XCTAssertEqual(d.handle(.keyUp(keyCode: 49, flags: [])), .pass)
    }

    func testFunctionKeyChordIgnoresFnFlag() {
        var d = HotkeyDetector(hotkey: try! Hotkey.parse("f5"))
        XCTAssertEqual(d.handle(.keyDown(keyCode: 96, flags: .fn, isRepeat: false)).signal, .pressed)
    }
}
