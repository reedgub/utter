import CoreGraphics
import Foundation
import UtterCore

/// A session-wide keyboard event tap on the main run loop.
///
/// Every event is passed on unchanged except the key events of a chord hotkey
/// (so ctrl+option+space does not also type a space). Esc and modifier keys are
/// only observed, so they still reach the app you are typing in.
final class EventTap {
    /// Set on events Utter posts itself (Cmd-V, typed text) so the tap ignores them.
    static let syntheticMarker: Int64 = 0x5574_7465_72 // "Utter"

    /// Returns true to swallow the event.
    typealias Handler = @MainActor (RawKeyEvent) -> Bool

    var handler: Handler?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isListenOnly = false

    var isRunning: Bool { tap != nil }

    /// Fails until the app has been granted Accessibility (or at least Input Monitoring).
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // An active tap can swallow a chord's key and needs Accessibility. If only
        // Input Monitoring is granted, a listen-only tap still works for fn and
        // modifier hotkeys.
        for options in [CGEventTapOptions.defaultTap, .listenOnly] {
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: options,
                eventsOfInterest: CGEventMask(mask),
                callback: eventTapCallback,
                userInfo: refcon
            ) else { continue }

            tap = port
            isListenOnly = options == .listenOnly
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
            CGEvent.tapEnable(tap: port, enable: true)
            log.info("event tap started (\(self.isListenOnly ? "listen-only" : "active", privacy: .public))")
            return true
        }
        return false
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables a tap whose callback is slow; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return pass
        }

        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return pass }
        guard let handler else { return pass }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = EventFlags(rawValue: event.flags.rawValue)
        let raw: RawKeyEvent
        switch type {
        case .keyDown:
            raw = .keyDown(keyCode: keyCode, flags: flags,
                           isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            raw = .keyUp(keyCode: keyCode, flags: flags)
        default:
            raw = .flagsChanged(keyCode: keyCode, flags: flags)
        }

        // The tap's run loop source is on the main run loop, so this is the main thread.
        let swallow = MainActor.assumeIsolated { handler(raw) }
        return swallow && !isListenOnly ? nil : pass
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}
