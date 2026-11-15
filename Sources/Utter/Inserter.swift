import AppKit
import Carbon.HIToolbox
import UtterCore

/// Puts text at the cursor of whatever app has focus.
@MainActor
enum Inserter {
    static func insert(_ text: String, method: InsertMethod, restoreClipboard: Bool) {
        switch method {
        case .paste: paste(text, restoreClipboard: restoreClipboard)
        case .type: type(text)
        }
    }

    // MARK: Paste

    private static func paste(_ text: String, restoreClipboard: Bool) {
        let pasteboard = NSPasteboard.general
        let saved = restoreClipboard ? snapshot(pasteboard) : nil

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if restoreClipboard {
            // Tells clipboard managers this entry is temporary and not worth keeping.
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
        let ourChangeCount = pasteboard.changeCount

        postKeystroke(keyCode: pasteKeyCode(), flags: .maskCommand)

        guard let saved else { return }
        // Give the target app time to read the pasteboard before putting the old
        // contents back, and do not clobber anything copied in the meantime.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MainActor.assumeIsolated {
                guard pasteboard.changeCount == ourChangeCount else { return }
                restore(saved, to: pasteboard)
            }
        }
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    /// The key that produces "v" while ⌘ is held in the current layout. On
    /// Dvorak that is not the QWERTY V key; on "Dvorak - QWERTY ⌘" it is.
    private static func pasteKeyCode() -> CGKeyCode {
        keyCode(producing: "v", withCommand: true) ?? CGKeyCode(KeyCodes.ansiV)
    }

    private static func keyCode(producing target: String, withCommand: Bool) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let modifiers: UInt32 = withCommand ? UInt32((cmdKey >> 8) & 0xFF) : 0

        return layoutData.withUnsafeBytes { buffer -> CGKeyCode? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                    &deadKeyState, 4, &length, &chars
                )
                if status == noErr, length == 1, String(utf16CodeUnits: chars, count: 1).lowercased() == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }

    // MARK: Type

    /// Sends the text as synthetic key events carrying Unicode strings, in small
    /// chunks because some apps drop long ones.
    private static func type(_ text: String) {
        let units = Array(text.replacingOccurrences(of: "\n", with: "\r").utf16)
        let source = CGEventSource(stateID: .hidSystemState)
        var start = 0
        while start < units.count {
            var end = min(start + 16, units.count)
            if end < units.count && UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[start..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                chunk.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
                event.post(tap: .cghidEventTap)
            }
            usleep(3_000)
            start = end
        }
    }

    // MARK: Keystrokes

    private static func postKeystroke(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: EventTap.syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}
