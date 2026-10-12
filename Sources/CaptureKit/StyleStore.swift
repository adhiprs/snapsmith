import AppKit

/// Persists `BeautifyStyle` in UserDefaults.
public enum StyleStore {
    /// Posted after `save`, so open windows can pick up edits made elsewhere.
    public static let didChange = Notification.Name("StyleStore.didChange")

    public static func load(from defaults: UserDefaults = .standard) -> BeautifyStyle {
        guard let dict = defaults.dictionary(forKey: "style") else { return BeautifyStyle() }
        var style = BeautifyStyle()
        if let v = dict["padding"] as? Double { style.padding = v }
        if let v = dict["cornerRadius"] as? Double { style.cornerRadius = v }
        if let v = dict["shadowRadius"] as? Double { style.shadowRadius = v }
        if let v = dict["gradientAngle"] as? Double { style.gradientAngle = v }
        if let v = dict["gradientStart"] as? String, let c = color(hex: v) { style.gradientStart = c }
        if let v = dict["gradientEnd"] as? String, let c = color(hex: v) { style.gradientEnd = c }
        style.inset = dict["inset"] as? Int
        if let v = dict["insetBalance"] as? Bool { style.insetBalance = v }
        style.background = (dict["background"] as? String).flatMap(background(from:)) ?? .gradient
        style.aspectRatio = (dict["aspectRatio"] as? String).flatMap(AspectRatio.init(rawValue:))
        style.watermark = dict["watermark"] as? String
        return style
    }

    public static func save(_ style: BeautifyStyle, to defaults: UserDefaults = .standard) {
        var dict: [String: Any] = [
            "padding": Double(style.padding),
            "cornerRadius": Double(style.cornerRadius),
            "shadowRadius": Double(style.shadowRadius),
            "gradientAngle": Double(style.gradientAngle),
            "gradientStart": hex(style.gradientStart),
            "gradientEnd": hex(style.gradientEnd),
            "insetBalance": style.insetBalance,
        ]
        dict["inset"] = style.inset
        dict["background"] = string(from: style.background)
        dict["aspectRatio"] = style.aspectRatio?.rawValue
        dict["watermark"] = style.watermark
        defaults.set(dict, forKey: "style")
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func string(from background: Background) -> String {
        switch background {
        case .gradient: return "gradient"
        case .wallpaper: return "wallpaper"
        case .image(let url): return "image:" + url.path
        }
    }

    static func background(from string: String) -> Background? {
        switch string {
        case "gradient": return .gradient
        case "wallpaper": return .wallpaper
        default:
            guard string.hasPrefix("image:") else { return nil }
            return .image(URL(fileURLWithPath: String(string.dropFirst("image:".count))))
        }
    }

    public static func color(hex: String) -> NSColor? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    public static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
