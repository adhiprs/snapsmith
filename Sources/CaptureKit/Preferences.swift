import AppKit

/// App behaviour settings (as opposed to `BeautifyStyle`), stored in UserDefaults.
/// Each setter posts `didChange` so menus and windows can stay in sync.
public enum Preferences {
    /// Posted when a preference changes.
    public static let didChange = Notification.Name("Preferences.didChange")

    // MARK: Beautify and preview

    static let beautifyKey = "beautify"
    static let closeAfterCopyKey = "closeAfterCopy"

    /// Copy the styled image instead of the raw capture.
    public static func beautify(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: beautifyKey)
    }

    public static func setBeautify(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: beautifyKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Close the preview window once its image is copied. On by default.
    public static func closeAfterCopy(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: closeAfterCopyKey) as? Bool ?? true
    }

    public static func setCloseAfterCopy(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: closeAfterCopyKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: Auto-redact

    static let autoRedactKey = "autoRedact"
    static let redactColorKey = "redactColor"
    static func categoryKey(_ category: RedactCategory) -> String { "autoRedact.\(category.rawValue)" }

    /// Off by default: it needs a text scan before every copy.
    public static func autoRedact(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: autoRedactKey)
    }

    public static func setAutoRedact(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: autoRedactKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Enabled categories. Only emails is on by default; the others are more likely to hide
    /// harmless text (long identifiers look like API keys, version numbers like IP addresses).
    public static func redactCategories(defaults: UserDefaults = .standard) -> Set<RedactCategory> {
        Set(RedactCategory.allCases.filter {
            defaults.object(forKey: categoryKey($0)) as? Bool ?? ($0 == .emails)
        })
    }

    public static func setRedactCategory(_ category: RedactCategory, enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: categoryKey(category))
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func redactColor(defaults: UserDefaults = .standard) -> NSColor {
        defaults.string(forKey: redactColorKey).flatMap(StyleStore.color(hex:)) ?? .black
    }

    public static func setRedactColor(_ color: NSColor, defaults: UserDefaults = .standard) {
        defaults.set(StyleStore.hex(color), forKey: redactColorKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    // MARK: Archive retention

    static let retentionKey = "archiveRetentionDays"
    public static let defaultRetentionDays = 3

    /// Days to keep captures in SnapSmith's archive; nil keeps them forever.
    public static func archiveRetentionDays(defaults: UserDefaults = .standard) -> Int? {
        guard let value = defaults.object(forKey: retentionKey) as? Int else { return defaultRetentionDays }
        return value > 0 ? value : nil  // 0 is stored for "keep forever"
    }

    public static func setArchiveRetentionDays(_ days: Int?, defaults: UserDefaults = .standard) {
        defaults.set(max(days ?? 0, 0), forKey: retentionKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
