import Foundation

/// Keyboard events as the event tap sees them, stripped of CoreGraphics types.
public enum RawKeyEvent: Equatable, Sendable {
    case keyDown(keyCode: UInt16, flags: EventFlags, isRepeat: Bool)
    case keyUp(keyCode: UInt16, flags: EventFlags)
    case flagsChanged(keyCode: UInt16, flags: EventFlags)
}

public enum HotkeySignal: Equatable, Sendable {
    case pressed
    case released
    /// Another key was pressed while the hotkey was held: the user is typing a
    /// shortcut such as fn+Delete, not dictating.
    case interrupted
    case escape
}

public struct DetectorOutput: Equatable, Sendable {
    public var signal: HotkeySignal?
    /// Whether the event should be removed before it reaches the focused app.
    /// Only a chord's own key events are swallowed; modifiers and Esc always pass.
    public var swallow: Bool

    public static let pass = DetectorOutput(signal: nil, swallow: false)
    static func signal(_ s: HotkeySignal, swallow: Bool = false) -> DetectorOutput {
        DetectorOutput(signal: s, swallow: swallow)
    }
}

/// Turns raw key events into press/release of the configured hotkey.
public struct HotkeyDetector: Sendable {
    public var hotkey: Hotkey {
        didSet { isDown = false }
    }
    public private(set) var isDown = false

    public init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    public mutating func reset() {
        isDown = false
    }

    public mutating func handle(_ event: RawKeyEvent) -> DetectorOutput {
        switch hotkey {
        case .modifier(let key):
            return handleModifier(key, event)
        case .chord(let keyCode, let modifiers, _):
            return handleChord(keyCode, modifiers, event)
        }
    }

    private mutating func handleModifier(_ key: ModifierKey, _ event: RawKeyEvent) -> DetectorOutput {
        switch event {
        case .flagsChanged(let code, let flags):
            let held = flags.contains(key.heldFlag)
            if held && !isDown && code == key.keyCode {
                isDown = true
                return .signal(.pressed)
            }
            // Checked on every flagsChanged, not only our key's, so a release we
            // missed (tap briefly disabled) is still noticed on the next change.
            if !held && isDown {
                isDown = false
                return .signal(.released)
            }
            return .pass
        case .keyDown(let code, _, let isRepeat):
            if isRepeat { return .pass }
            if code == KeyCodes.escape { return .signal(.escape) }
            return isDown ? .signal(.interrupted) : .pass
        case .keyUp:
            return .pass
        }
    }

    private mutating func handleChord(_ keyCode: UInt16, _ modifiers: EventFlags, _ event: RawKeyEvent) -> DetectorOutput {
        switch event {
        case .keyDown(let code, let flags, let isRepeat):
            if code == keyCode && (isDown || flags.intersection(.chordModifiers) == modifiers) {
                if isDown || isRepeat { return DetectorOutput(signal: nil, swallow: true) }
                isDown = true
                return .signal(.pressed, swallow: true)
            }
            if isRepeat { return .pass }
            if code == KeyCodes.escape { return .signal(.escape) }
            return isDown ? .signal(.interrupted) : .pass
        case .keyUp(let code, _):
            if code == keyCode && isDown {
                isDown = false
                return .signal(.released, swallow: true)
            }
            return .pass
        case .flagsChanged:
            return .pass
        }
    }
}
