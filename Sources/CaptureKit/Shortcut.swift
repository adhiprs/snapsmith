import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut: a virtual key code plus Carbon modifier flags, the form
/// `RegisterEventHotKey` takes.
public struct Shortcut: Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32  // Carbon masks: cmdKey, optionKey, controlKey, shiftKey

    public init(keyCode: Int, modifiers: Int) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
    }

    /// Shortcuts need ⌘, ⌥ or ⌃ so they don't swallow ordinary typing; function keys are
    /// fine on their own.
    public var isValid: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 || Self.functionKeys.contains(Int(keyCode))
    }

    /// macOS's own screenshot shortcuts (⌘⇧3/4/5, ⌃⌘⇧3/4). The system handles these before
    /// any app, so a SnapSmith hotkey on one of them would never fire.
    public var isSystemScreenshotShortcut: Bool {
        let cmdShift = UInt32(cmdKey | shiftKey), ctrlCmdShift = UInt32(cmdKey | shiftKey | controlKey)
        let digits = [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].map(UInt32.init)
        return (modifiers == cmdShift && digits.contains(keyCode))
            || (modifiers == ctrlCmdShift && digits.prefix(2).contains(keyCode))
    }

    /// macOS shortcuts that are switched on in System Settings → Keyboard → Keyboard Shortcuts
    /// (screenshots, Spotlight, Mission Control…). macOS handles these before any app.
    /// Other apps' shortcuts can't be queried; macOS has no public API for that.
    public var isReservedBySystem: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return isSystemScreenshotShortcut
        }
        return list.contains { entry in
            (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode as String] as? Int).map(UInt32.init) == keyCode
                && (entry[kHISymbolicHotKeyModifiers as String] as? Int).map { UInt32($0) & Self.modifierMask } == modifiers & Self.modifierMask
        }
    }

    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)

    /// "⌥⇧4", in Apple's modifier order ⌃⌥⇧⌘.
    public var displayString: String { Self.modifierSymbols(modifiers) + Self.keyName(Int(keyCode)) }

    /// "⌃⌥⇧⌘" symbols for Carbon modifier flags.
    public static func modifierSymbols(_ modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    /// The unmodified character the key types on the current layout ("4", "a"), for menu
    /// key equivalents; nil for keys without one.
    public var keyCharacter: String? {
        Self.specialKeyNames[Int(keyCode)] == nil ? Self.layoutCharacter(Int(keyCode)) : nil
    }

    // MARK: Key names

    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
                                         kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
                                         kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    static let specialKeyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        ]
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (index, code) in functions.enumerated() { names[code] = "F\(index + 1)" }
        return names
    }()

    static func keyName(_ keyCode: Int) -> String {
        specialKeyNames[keyCode] ?? layoutCharacter(keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    /// Translates a key code with the current keyboard layout, so e.g. AZERTY shows its own letters.
    static func layoutCharacter(_ keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length > 0 else { return nil }
        let string = String(utf16CodeUnits: characters, count: length)
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
    }
}

/// The actions that have global shortcuts, with SnapSmith's defaults.
public enum ShortcutAction: String, CaseIterable {
    case captureArea, captureWindow, captureAndCopy, captureText

    public var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureAndCopy: return "Capture & Copy"
        case .captureText: return "Capture Text"
        }
    }

    public var defaultShortcut: Shortcut {
        let optionShift = optionKey | shiftKey
        switch self {
        case .captureArea: return Shortcut(keyCode: kVK_ANSI_4, modifiers: optionShift)
        case .captureWindow: return Shortcut(keyCode: kVK_ANSI_5, modifiers: optionShift)
        case .captureAndCopy: return Shortcut(keyCode: kVK_ANSI_3, modifiers: optionShift)
        case .captureText: return Shortcut(keyCode: kVK_ANSI_2, modifiers: optionShift)
        }
    }
}

extension Preferences {
    static func shortcutKey(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }

    /// The action's shortcut; nil when the user cleared it.
    public static func shortcut(for action: ShortcutAction, defaults: UserDefaults = .standard) -> Shortcut? {
        guard let stored = defaults.dictionary(forKey: shortcutKey(action)) else { return action.defaultShortcut }
        guard let keyCode = stored["keyCode"] as? Int, let modifiers = stored["modifiers"] as? Int else { return nil }
        return Shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    /// Pass nil to clear (disable) the shortcut.
    public static func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction, defaults: UserDefaults = .standard) {
        // An empty dictionary marks "cleared", distinct from "never set" (which means the default).
        let stored: [String: Int] = shortcut.map { ["keyCode": Int($0.keyCode), "modifiers": Int($0.modifiers)] } ?? [:]
        defaults.set(stored, forKey: shortcutKey(action))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func resetShortcuts(defaults: UserDefaults = .standard) {
        ShortcutAction.allCases.forEach { defaults.removeObject(forKey: shortcutKey($0)) }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
