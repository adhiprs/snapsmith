import CoreGraphics

/// Inset: when a capture is surrounded by a solid background colour, measure the empty
/// margin on each side and re-pad the content with that colour.
/// With `balance`, every side gets exactly `inset` pixels so the content is centred.
/// Without it, the shared excess is trimmed but each side keeps its relative offset.
public enum Inset {
    public struct Margins: Equatable {
        public var top, left, bottom, right: Int
        public init(top: Int, left: Int, bottom: Int, right: Int) {
            (self.top, self.left, self.bottom, self.right) = (top, left, bottom, right)
        }
    }

    public struct RGBA: Equatable {
        public var r, g, b, a: UInt8
        public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }

        func matches(_ other: RGBA, tolerance: Int) -> Bool {
            abs(Int(r) - Int(other.r)) <= tolerance && abs(Int(g) - Int(other.g)) <= tolerance &&
                abs(Int(b) - Int(other.b)) <= tolerance && abs(Int(a) - Int(other.a)) <= tolerance
        }
    }

    /// Applies the inset, or returns nil when there's no solid border to work with.
    public static func apply(to image: CGImage, inset: Int, balance: Bool, tolerance: Int = 8) -> CGImage? {
        guard let bitmap = Bitmap(image),
              let color = borderColor(of: bitmap, tolerance: tolerance),
              let margins = contentMargins(of: bitmap, background: color, tolerance: tolerance)
        else { return nil }

        let target: Margins
        if balance {
            target = Margins(top: inset, left: inset, bottom: inset, right: inset)
        } else {
            let shared = min(margins.top, margins.left, margins.bottom, margins.right)
            target = Margins(top: margins.top - shared + inset, left: margins.left - shared + inset,
                             bottom: margins.bottom - shared + inset, right: margins.right - shared + inset)
        }
        return repad(image, content: margins, to: target, color: color)
    }

    /// The colour that dominates the outermost pixel ring, if it covers ≥ 90% of it.
    static func borderColor(of bitmap: Bitmap, tolerance: Int) -> RGBA? {
        var edge: [RGBA] = []
        for x in 0..<bitmap.width { edge.append(bitmap[x, 0]); edge.append(bitmap[x, bitmap.height - 1]) }
        for y in 0..<bitmap.height { edge.append(bitmap[0, y]); edge.append(bitmap[bitmap.width - 1, y]) }

        // Most common colour, bucketed so antialiasing noise doesn't split the vote.
        var counts: [UInt32: (count: Int, sample: RGBA)] = [:]
        for p in edge {
            let key = UInt32(p.r >> 3) << 15 | UInt32(p.g >> 3) << 10 | UInt32(p.b >> 3) << 5 | UInt32(p.a >> 3)
            counts[key, default: (0, p)].count += 1
        }
        guard let candidate = counts.values.max(by: { $0.count < $1.count })?.sample else { return nil }
        let matching = edge.filter { $0.matches(candidate, tolerance: tolerance) }.count
        return Double(matching) >= Double(edge.count) * 0.9 ? candidate : nil
    }

    /// Width of the solid-colour band on each side. Nil if the image is entirely background.
    static func contentMargins(of bitmap: Bitmap, background: RGBA, tolerance: Int) -> Margins? {
        func rowIsBackground(_ y: Int) -> Bool {
            (0..<bitmap.width).allSatisfy { bitmap[$0, y].matches(background, tolerance: tolerance) }
        }
        func columnIsBackground(_ x: Int, _ rows: Range<Int>) -> Bool {
            rows.allSatisfy { bitmap[x, $0].matches(background, tolerance: tolerance) }
        }
        guard let top = (0..<bitmap.height).first(where: { !rowIsBackground($0) }),
              let bottomRow = (0..<bitmap.height).reversed().first(where: { !rowIsBackground($0) })
        else { return nil }
        let rows = top..<(bottomRow + 1)
        let left = (0..<bitmap.width).first(where: { !columnIsBackground($0, rows) }) ?? 0
        let rightColumn = (0..<bitmap.width).reversed().first(where: { !columnIsBackground($0, rows) }) ?? bitmap.width - 1
        return Margins(top: top, left: left, bottom: bitmap.height - 1 - bottomRow, right: bitmap.width - 1 - rightColumn)
    }

    private static func repad(_ image: CGImage, content m: Margins, to t: Margins, color: RGBA) -> CGImage? {
        let contentWidth = image.width - m.left - m.right
        let contentHeight = image.height - m.top - m.bottom
        // CGImage cropping uses a top-left origin.
        guard let content = image.cropping(to: CGRect(x: m.left, y: m.top, width: contentWidth, height: contentHeight)),
              let ctx = Bitmap.context(width: contentWidth + t.left + t.right, height: contentHeight + t.top + t.bottom)
        else { return nil }
        ctx.setFillColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                         blue: CGFloat(color.b) / 255, alpha: CGFloat(color.a) / 255)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        // CGContext drawing uses a bottom-left origin, so the bottom margin is the y offset.
        ctx.draw(content, in: CGRect(x: t.left, y: t.bottom, width: contentWidth, height: contentHeight))
        return ctx.makeImage()
    }
}

/// RGBA8 pixel buffer with a top-left origin.
struct Bitmap {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init?(_ image: CGImage) {
        guard let ctx = Bitmap.context(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        width = image.width
        height = image.height
        pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                           count: ctx.bytesPerRow * height))
        bytesPerRow = ctx.bytesPerRow
    }

    private let bytesPerRow: Int

    subscript(x: Int, y: Int) -> Inset.RGBA {
        let i = y * bytesPerRow + x * 4
        return Inset.RGBA(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2], a: pixels[i + 3])
    }

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
