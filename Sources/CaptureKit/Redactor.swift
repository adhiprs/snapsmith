import AppKit
import Vision

/// Kinds of sensitive text auto-redact looks for.
public enum RedactCategory: String, CaseIterable {
    case emails
    case creditCards = "credit-cards"
    case ipAddresses = "ip-addresses"
    case apiKeys = "api-keys"

    public var title: String {
        switch self {
        case .emails: return "Emails"
        case .creditCards: return "Credit cards"
        case .ipAddresses: return "IP addresses"
        case .apiKeys: return "API keys"
        }
    }

    /// Candidate finder. Matches are then confirmed by `isPlausible`, which keeps the
    /// patterns simple while avoiding false positives (random digit runs, times, long words).
    var pattern: String {
        switch self {
        case .emails:
            return "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}"
        case .creditCards:
            return "\\b\\d(?:[ -]?\\d){12,18}\\b"
        case .ipAddresses:
            let octet = "(?:25[0-5]|2[0-4]\\d|1\\d\\d|[1-9]?\\d)"
            let v4 = "\\b(?:\(octet)\\.){3}\(octet)\\b"
            let v6 = "(?<![0-9A-Za-z_:])[0-9A-Fa-f:]{2,39}(?![0-9A-Za-z_:])"
            return "\(v4)|\(v6)"
        case .apiKeys:
            return "\\b[A-Za-z0-9_-]{32,}\\b"
        }
    }

    var regex: NSRegularExpression {
        // The patterns are constants, so a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    /// Second-stage check on a regex match.
    func isPlausible(_ text: String) -> Bool {
        switch self {
        case .emails:
            return true
        case .creditCards:
            let digits = text.filter(\.isNumber)
            return (13...19).contains(digits.count) && Self.passesLuhn(digits)
        case .ipAddresses:
            // IPv4 candidates were matched strictly; IPv6 candidates must really parse,
            // which rules out times such as 10:30 or 10:30:45.
            if text.contains(".") { return true }
            var address = in6_addr()
            return text.contains(":") && inet_pton(AF_INET6, text, &address) == 1
        case .apiKeys:
            // Long identifiers made only of letters (or only digits) are words or numbers, not secrets.
            return text.contains(where: \.isLetter) && text.contains(where: \.isNumber)
        }
    }

    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            guard var value = character.wholeNumberValue else { return false }
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }
}

/// A piece of text to hide, in image pixels with a top-left origin.
/// `category` is nil for regions the user added by hand.
public struct RedactRegion: Equatable {
    public var rect: CGRect
    public var category: RedactCategory?
    public var text: String

    public init(rect: CGRect, category: RedactCategory?, text: String) {
        (self.rect, self.category, self.text) = (rect, category, text)
    }

    /// True for boxes the user drew; those are covered exactly as drawn.
    public var isDrawn: Bool { category == nil && text.isEmpty }

    /// The area actually covered: text regions get a small margin so glyph edges don't peek out.
    public var coveredRect: CGRect {
        guard !isDrawn else { return rect }
        let pad = max(2, rect.height * 0.15)
        return rect.insetBy(dx: -pad, dy: -pad)
    }
}

/// One OCR'd line, kept so boxes for any part of it can be computed later.
public struct TextLine {
    public let text: String
    let candidate: VNRecognizedText
    let imageSize: CGSize

    /// Pixel rect (top-left origin) of a range of `text`.
    func rect(for range: Range<String.Index>) -> CGRect? {
        guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { return nil }
        return Redactor.pixelRect(box, in: imageSize)
    }
}

/// Auto-redact: OCR the capture, match each line against the enabled patterns, and cover
/// just the matched characters (via `VNRecognizedText.boundingBox(for:)`).
public enum Redactor {
    public static func findRegions(in image: CGImage, categories: Set<RedactCategory>) throws -> [RedactRegion] {
        guard !categories.isEmpty else { return [] }
        return regions(in: try recognize(image), categories: categories)
    }

    /// The slow part (OCR). Callers cache this per capture and derive regions from it.
    public static func recognize(_ image: CGImage) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false  // keep keys and addresses exactly as shown
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { TextLine(text: $0.string, candidate: $0, imageSize: size) }
        }
    }

    /// Auto-redact matches for the enabled categories.
    public static func regions(in lines: [TextLine], categories: Set<RedactCategory>) -> [RedactRegion] {
        lines.flatMap { line in
            matches(in: line.text, categories: categories).compactMap { category, range in
                line.rect(for: range).map { RedactRegion(rect: $0, category: category, text: String(line.text[range])) }
            }
        }
    }

    /// Every word as a clickable box, for manual redaction.
    public static func words(in lines: [TextLine]) -> [RedactRegion] {
        lines.flatMap { line in
            wordRanges(in: line.text).compactMap { range in
                line.rect(for: range).map { RedactRegion(rect: $0, category: nil, text: String(line.text[range])) }
            }
        }
    }

    /// Whitespace-separated words. Pure, so it's unit-testable.
    static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isWhitespace {
                if let s = start { ranges.append(s..<index); start = nil }
            } else if start == nil {
                start = index
            }
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }

    /// Pure text matching, so it's unit-testable without OCR. Earlier categories win
    /// when matches overlap (an email's digits shouldn't also count as an IP).
    static func matches(in text: String, categories: Set<RedactCategory>) -> [(RedactCategory, Range<String.Index>)] {
        var found: [(RedactCategory, Range<String.Index>)] = []
        let whole = NSRange(text.startIndex..., in: text)
        for category in RedactCategory.allCases where categories.contains(category) {
            for match in category.regex.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text), !range.isEmpty,
                      category.isPlausible(String(text[range])),
                      !found.contains(where: { $0.1.overlaps(range) })
                else { continue }
                found.append((category, range))
            }
        }
        return found
    }

    /// Covers each region with a solid block, padded slightly so glyph edges don't peek out.
    public static func apply(_ regions: [RedactRegion], to image: CGImage, color: NSColor) -> CGImage? {
        guard !regions.isEmpty else { return image }
        guard let ctx = Bitmap.context(width: image.width, height: image.height) else { return nil }
        let height = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setFillColor((color.usingColorSpace(.sRGB) ?? color).cgColor)
        for region in regions {
            let r = region.coveredRect
            let radius = min(4, r.height / 4, r.width / 4)
            // Regions are top-left origin; the context is bottom-left.
            let flipped = CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
            ctx.addPath(CGPath(roundedRect: flipped, cornerWidth: radius, cornerHeight: radius, transform: nil))
        }
        ctx.fillPath()
        return ctx.makeImage()
    }

    /// Vision's normalized, bottom-left rect → pixel rect with a top-left origin.
    static func pixelRect(_ box: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
               width: box.width * size.width, height: box.height * size.height)
    }
}
