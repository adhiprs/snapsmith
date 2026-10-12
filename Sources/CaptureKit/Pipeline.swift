import AppKit

/// The full capture → output pipeline. Order matters: redact first so the blocks are
/// part of the screenshot itself (and survive inset trimming), then annotations, then beautify.
public enum Pipeline {
    /// - Parameters:
    ///   - redactions: regions to cover; empty when auto-redact is off.
    ///   - style: nil returns the (redacted) capture without beautifying.
    public static func render(_ source: CGImage, redactions: [RedactRegion], redactColor: NSColor,
                              annotations: [Annotation] = [], style: BeautifyStyle?, scale: CGFloat) -> CGImage? {
        guard let redacted = Redactor.apply(redactions, to: source, color: redactColor),
              let annotated = Annotator.apply(annotations, to: redacted, scale: scale)
        else { return nil }
        guard let style else { return annotated }
        return Beautifier.beautify(annotated, style: style, scale: scale)
    }

    /// Capture & Copy: renders a capture with the saved settings (auto-redact, beautify)
    /// without the preview window.
    /// Returns the file to copy: the raw capture when nothing changes it, else the Output file.
    /// Throws if auto-redact is on and OCR fails, so nothing unredacted gets copied.
    public static func quickOutput(forRaw raw: URL) throws -> URL {
        guard let source = Beautifier.loadImage(raw) else { throw CaptureError.unreadableImage }
        let redactions = Preferences.autoRedact()
            ? Redactor.regions(in: try Redactor.recognize(source), categories: Preferences.redactCategories())
            : []
        let beautify = Preferences.beautify()
        guard beautify || !redactions.isEmpty else { return raw }
        guard let output = render(source, redactions: redactions, redactColor: Preferences.redactColor(),
                                  style: beautify ? StyleStore.load() : nil, scale: Beautifier.scale(of: raw))
        else { throw CaptureError.unreadableImage }
        return try Beautifier.writeOutput(output, forRaw: raw)
    }
}
