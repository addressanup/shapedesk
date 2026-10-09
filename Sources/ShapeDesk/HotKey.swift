import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut in Carbon's terms, plus a printable key name.
struct KeyCombo: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    static let standard = KeyCombo(keyCode: UInt32(kVK_ANSI_D),
                                   modifiers: UInt32(controlKey | optionKey | cmdKey), key: "D")

    var label: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20"
    ]

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Nil unless the key press works as a global shortcut: it needs ⌘, ⌃ or ⌥,
    /// except for function keys, which may stand alone.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbon = [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey),
                      (.shift, shiftKey), (.command, cmdKey)]
            .filter { flags.contains($0.0) }.reduce(UInt32(0)) { $0 | UInt32($1.1) }
        let code = Int(event.keyCode)
        // The unmodified character, so ⇧⌘1 reads "⇧⌘1" rather than "⇧⌘!".
        let name = Self.namedKeys[code]
            ?? event.characters(byApplyingModifiers: [])?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        let isFunctionKey = Self.namedKeys[code]?.hasPrefix("F") == true
        guard !name.isEmpty, isFunctionKey || carbon & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        self.init(keyCode: UInt32(code), modifiers: carbon, key: name)
    }
}

/// One system-wide hotkey. Carbon hotkeys need no Accessibility permission.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            // Carbon delivers hotkey events on the main thread.
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &pressed, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Replaces the current shortcut. False when macOS refuses the combination.
    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard let combo else { return true }
        let id = EventHotKeyID(signature: OSType(0x5344_4B59), id: 1) // "SDKY"
        return RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }
}
