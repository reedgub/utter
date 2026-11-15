import Foundation

/// Mirrors the raw bits of `CGEventFlags` so hotkey logic can be tested without
/// CoreGraphics. The low bits are the device-dependent masks from IOKit's
/// NX_DEVICE*KEYMASK, which tell left and right modifiers apart.
public struct EventFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let shift = EventFlags(rawValue: 0x0002_0000)
    public static let control = EventFlags(rawValue: 0x0004_0000)
    public static let option = EventFlags(rawValue: 0x0008_0000)
    public static let command = EventFlags(rawValue: 0x0010_0000)
    public static let fn = EventFlags(rawValue: 0x0080_0000)

    public static let leftControl = EventFlags(rawValue: 0x0000_0001)
    public static let leftShift = EventFlags(rawValue: 0x0000_0002)
    public static let rightShift = EventFlags(rawValue: 0x0000_0004)
    public static let leftCommand = EventFlags(rawValue: 0x0000_0008)
    public static let rightCommand = EventFlags(rawValue: 0x0000_0010)
    public static let leftOption = EventFlags(rawValue: 0x0000_0020)
    public static let rightOption = EventFlags(rawValue: 0x0000_0040)
    public static let rightControl = EventFlags(rawValue: 0x0000_2000)

    /// The modifiers compared when matching a chord. fn is left out because macOS
    /// sets it on arrow and function keys by itself.
    public static let chordModifiers: EventFlags = [.shift, .control, .option, .command]
}

/// A single modifier key used on its own as a push-to-talk key.
public enum ModifierKey: String, CaseIterable, Sendable {
    case fn
    case leftControl = "left_control", rightControl = "right_control"
    case leftOption = "left_option", rightOption = "right_option"
    case leftCommand = "left_command", rightCommand = "right_command"
    case leftShift = "left_shift", rightShift = "right_shift"

    /// Virtual key code reported in flagsChanged events.
    public var keyCode: UInt16 {
        switch self {
        case .fn: return 63
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .leftShift: return 56
        case .leftOption: return 58
        case .leftControl: return 59
        case .rightShift: return 60
        case .rightOption: return 61
        case .rightControl: return 62
        }
    }

    /// The flag bit that is set while this exact key is down.
    public var heldFlag: EventFlags {
        switch self {
        case .fn: return .fn
        case .leftControl: return .leftControl
        case .rightControl: return .rightControl
        case .leftOption: return .leftOption
        case .rightOption: return .rightOption
        case .leftCommand: return .leftCommand
        case .rightCommand: return .rightCommand
        case .leftShift: return .leftShift
        case .rightShift: return .rightShift
        }
    }

    public var displayName: String {
        switch self {
        case .fn: return "fn"
        case .leftControl: return "left ⌃"
        case .rightControl: return "right ⌃"
        case .leftOption: return "left ⌥"
        case .rightOption: return "right ⌥"
        case .leftCommand: return "left ⌘"
        case .rightCommand: return "right ⌘"
        case .leftShift: return "left ⇧"
        case .rightShift: return "right ⇧"
        }
    }
}

public enum Hotkey: Equatable, Sendable {
    case modifier(ModifierKey)
    case chord(keyCode: UInt16, modifiers: EventFlags, display: String)

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public var displayName: String {
        switch self {
        case .modifier(let key): return key.displayName
        case .chord(_, _, let display): return display
        }
    }

    public static func parse(_ input: String) throws -> Hotkey {
        let normalized = input.lowercased().replacingOccurrences(of: " ", with: "")
        guard !normalized.isEmpty else { throw ParseError(description: "hotkey is empty") }

        if let key = modifierAliases[normalized.replacingOccurrences(of: "-", with: "_")] { return .modifier(key) }
        if ["option", "alt", "command", "cmd", "control", "ctrl", "shift"].contains(normalized) {
            throw ParseError(description: "say which side: \"left_\(normalized)\" or \"right_\(normalized)\"")
        }

        // "page-up" and "page_up" both work; a lone "-" stays the minus key.
        let parts = normalized.split(separator: "+", omittingEmptySubsequences: false).map { part in
            part.count > 1 ? part.replacingOccurrences(of: "-", with: "_") : String(part)
        }
        guard let keyName = parts.last, !keyName.isEmpty, parts.dropLast().allSatisfy({ !$0.isEmpty }) else {
            throw ParseError(description: "could not read hotkey \"\(input)\"")
        }

        var modifiers: EventFlags = []
        var symbols = ""
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            default: throw ParseError(description: "unknown modifier \"\(part)\" in \"\(input)\"")
            }
        }
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }

        guard let code = KeyCodes.byName[keyName] else {
            throw ParseError(description: "unknown key \"\(keyName)\" in \"\(input)\"")
        }
        if code == KeyCodes.escape {
            throw ParseError(description: "Esc is reserved for cancelling")
        }
        if modifiers.isEmpty && !KeyCodes.functionKeys.contains(code) {
            throw ParseError(description: "\"\(keyName)\" on its own would stop you typing it; add a modifier such as ctrl+option+\(keyName)")
        }
        return .chord(keyCode: code, modifiers: modifiers, display: symbols + KeyCodes.display(keyName))
    }

    static let modifierAliases: [String: ModifierKey] = {
        var map: [String: ModifierKey] = ["fn": .fn, "globe": .fn, "function": .fn]
        let sides: [(String, ModifierKey, ModifierKey)] = [
            ("control", .leftControl, .rightControl), ("ctrl", .leftControl, .rightControl),
            ("option", .leftOption, .rightOption), ("opt", .leftOption, .rightOption), ("alt", .leftOption, .rightOption),
            ("command", .leftCommand, .rightCommand), ("cmd", .leftCommand, .rightCommand),
            ("shift", .leftShift, .rightShift),
        ]
        for (name, left, right) in sides {
            map["left_\(name)"] = left
            map["right_\(name)"] = right
            map["l\(name)"] = left
            map["r\(name)"] = right
        }
        return map
    }()
}

/// ANSI virtual key codes (physical positions, as in Carbon's kVK_* constants).
public enum KeyCodes {
    public static let escape: UInt16 = 53
    public static let returnKey: UInt16 = 36
    public static let ansiV: UInt16 = 9

    public static let functionKeys: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    public static let byName: [String: UInt16] = {
        var m: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "forward_delete": 117,
            "home": 115, "end": 119, "page_up": 116, "page_down": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let fKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in fKeys.enumerated() { m["f\(i + 1)"] = code }
        return m
    }()

    static func display(_ name: String) -> String {
        switch name {
        case "space": return "Space"
        case "return", "enter": return "↩"
        case "tab": return "⇥"
        case "delete", "backspace": return "⌫"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return name.uppercased()
        }
    }
}
