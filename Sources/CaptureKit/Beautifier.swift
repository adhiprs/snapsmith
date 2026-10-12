import AppKit
import CoreGraphics

/// Canvas shape presets for social posts. nil in `BeautifyStyle` means "fit the capture".
public enum AspectRatio: String, CaseIterable {
    case wide = "16:9", standard = "4:3", photo = "3:2", square = "1:1", portrait = "4:5", story = "9:16"

    public var value: CGFloat {
        let parts = rawValue.split(separator: ":").compactMap { Double($0) }
        return CGFloat(parts[0] / parts[1])
    }
}

/// What's drawn behind the screenshot.
public enum Background: Equatable {
    case gradient            // gradientStart → gradientEnd (equal colours = plain)
    case wallpaper           // the current desktop picture
    case image(URL)          // a picture file the user chose
}

/// "Beautify": place the screenshot on a background with padding, rounded corners and a
/// drop shadow.
///
/// Lengths are in points: a Retina capture is drawn at `scale` 2, so a padding of 24 adds
/// 48 px per side.
public struct BeautifyStyle: Equatable {
    public var padding: CGFloat = 32
    public var cornerRadius: CGFloat = 10
    public var shadowRadius: CGFloat = 20
    public var shadowOpacity: CGFloat = 0.35
    public var gradientStart = NSColor(srgbRed: 0x5B / 255, green: 0x6C / 255, blue: 0xFF / 255, alpha: 1)
    public var gradientEnd = NSColor(srgbRed: 0xB0 / 255, green: 0x5C / 255, blue: 0xFF / 255, alpha: 1)
    public var gradientAngle: CGFloat = 50    // degrees, CSS-style (0 = bottom→top)
    public var inset: Int? = nil              // nil = off; see `Inset`
    public var insetBalance = true
    public var background: Background = .gradient
    public var aspectRatio: AspectRatio? = nil
    /// Text under the screenshot's bottom-right corner. nil = off.
    public var watermark: String? = nil

    public init() {}
}

public enum Beautifier {
    /// Height of the band under the screenshot that holds the watermark, in points.
    static let watermarkBand: CGFloat = 28

    /// Returns a new image `padding × scale` pixels larger on every side (plus the watermark
    /// band, then widened or heightened to the aspect ratio).
    /// - Parameter scale: pixels per point of the capture (2 on Retina displays).
    public static func beautify(_ source: CGImage, style: BeautifyStyle = BeautifyStyle(),
                                scale: CGFloat = 1) -> CGImage? {
        // Inset is skipped silently when the capture has no solid border colour.
        let image = style.inset.flatMap {
            Inset.apply(to: source, inset: Int((CGFloat($0) * scale).rounded()), balance: style.insetBalance)
        } ?? source
        let padding = (style.padding * scale).rounded()
        let shadowRadius = style.shadowRadius * scale
        let band = style.watermark?.isEmpty == false ? (watermarkBand * scale).rounded() : 0
        let imageSize = CGSize(width: image.width, height: image.height)
        let canvas = canvasSize(content: CGSize(width: imageSize.width + padding * 2,
                                                height: imageSize.height + padding * 2 + band),
                                ratio: style.aspectRatio)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        drawBackground(in: ctx, size: canvas, style: style, space: space)

        // Centre the screenshot plus its watermark band; the band sits under the screenshot.
        let frame = CGRect(x: ((canvas.width - imageSize.width) / 2).rounded(),
                           y: ((canvas.height - imageSize.height - band) / 2).rounded() + band,
                           width: imageSize.width, height: imageSize.height)
        let radius = min(style.cornerRadius * scale, imageSize.width / 2, imageSize.height / 2)
        let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Shadow: fill the shape once with a shadow set, then draw the clipped image on top.
        if shadowRadius > 0, style.shadowOpacity > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -shadowRadius / 3),
                          blur: shadowRadius,
                          color: NSColor.black.withAlphaComponent(style.shadowOpacity).cgColor)
            ctx.addPath(shape)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        ctx.draw(image, in: frame)
        ctx.restoreGState()

        if let text = style.watermark, !text.isEmpty {
            drawWatermark(text, in: ctx, rightEdge: frame.maxX, bandMinY: frame.minY - band, band: band, scale: scale)
        }
        return ctx.makeImage()
    }

    /// Smallest canvas that holds `content` and has the given aspect ratio.
    static func canvasSize(content: CGSize, ratio: AspectRatio?) -> CGSize {
        guard let ratio else { return CGSize(width: content.width.rounded(), height: content.height.rounded()) }
        let r = ratio.value
        if content.width / content.height < r {
            return CGSize(width: (content.height * r).rounded(), height: content.height.rounded())
        }
        return CGSize(width: content.width.rounded(), height: (content.width / r).rounded())
    }

    private static func drawWatermark(_ text: String, in ctx: CGContext, rightEdge: CGFloat,
                                      bandMinY: CGFloat, band: CGFloat, scale: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -scale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12 * scale, weight: .semibold),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        string.draw(at: NSPoint(x: rightEdge - size.width, y: bandMinY + (band - size.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawBackground(in ctx: CGContext, size: CGSize, style: BeautifyStyle, space: CGColorSpace) {
        let url: URL?
        switch style.background {
        case .gradient: url = nil
        case .wallpaper: url = currentWallpaperURL()
        case .image(let file): url = file
        }
        // A missing or unreadable picture falls back to the gradient rather than failing the render.
        if let url, let picture = BackgroundCache.image(at: url) {
            drawAspectFill(picture, in: ctx, size: size)
        } else {
            drawGradient(in: ctx, size: size, style: style, space: space)
        }
    }

    /// The main screen's desktop picture. AppKit screen state is read on the main thread;
    /// renders run on background queues, and the main thread never waits on them.
    static func currentWallpaperURL() -> URL? {
        let read = { NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) } }
        return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
    }

    private static func drawAspectFill(_ image: CGImage, in ctx: CGContext, size: CGSize) {
        let fill = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let drawn = CGSize(width: CGFloat(image.width) * fill, height: CGFloat(image.height) * fill)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                   width: drawn.width, height: drawn.height))
    }

    private static func drawGradient(in ctx: CGContext, size: CGSize, style: BeautifyStyle, space: CGColorSpace) {
        let colors = [style.gradientStart.cgColor, style.gradientEnd.cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { return }
        // CSS angle: 0deg points up, 90deg points right. The line spans the canvas
        // through its centre, long enough to reach the corners.
        let radians = style.gradientAngle * .pi / 180
        let direction = CGVector(dx: sin(radians), dy: cos(radians))
        let halfLength = (abs(size.width * direction.dx) + abs(size.height * direction.dy)) / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let start = CGPoint(x: center.x - direction.dx * halfLength, y: center.y - direction.dy * halfLength)
        let end = CGPoint(x: center.x + direction.dx * halfLength, y: center.y + direction.dy * halfLength)
        ctx.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    /// Pixels per point for a capture file. screencapture writes 144 DPI for Retina
    /// selections; a 72 DPI tag is ambiguous, so fall back to the main screen's scale.
    public static func scale(of url: URL) -> CGFloat {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 72 {
            return CGFloat(dpi / 72)
        }
        return NSScreen.main?.backingScaleFactor ?? 1
    }

    /// Beautifies a raw capture file and writes it to `ScreenCapturer.outputURL(forRaw:)`.
    public static func renderOutput(forRaw raw: URL, style: BeautifyStyle) throws -> URL {
        guard let image = loadImage(raw), let styled = beautify(image, style: style, scale: scale(of: raw))
        else { throw CaptureError.unreadableImage }
        return try writeOutput(styled, forRaw: raw)
    }

    /// Writes an already-beautified image to `ScreenCapturer.outputURL(forRaw:)`.
    public static func writeOutput(_ image: CGImage, forRaw raw: URL) throws -> URL {
        let output = ScreenCapturer.outputURL(forRaw: raw)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writePNG(image, to: output)
        return output
    }

    /// Loads the first frame (dynamic HEIC wallpapers have several).
    public static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw CaptureError.unreadableImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.unreadableImage }
    }
}

/// Wallpapers can be 6K HEICs; decode each once and keep a downscaled copy so dragging
/// a style slider stays fast.
enum BackgroundCache {
    private static var images: [URL: CGImage] = [:]
    private static let lock = NSLock()
    private static let maxPixels: CGFloat = 4096

    static func image(at url: URL) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = images[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        images[url] = image
        return image
    }
}
