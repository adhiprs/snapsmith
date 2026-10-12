import AppKit

/// Markup drawn on top of a capture. In the preview: key 1 adds text, 2 an arrow, 4 a shape;
/// pressing a tool's key again cycles its variant (text size, arrow style, shape).
/// Points are capture pixels with a top-left origin; sizes are points, multiplied by the
/// capture's scale when drawn.
public enum Annotation: Equatable {
    case text(String, origin: CGPoint, size: TextSize)
    case arrow(from: CGPoint, to: CGPoint, style: ArrowStyle)
    case shape(from: CGPoint, to: CGPoint, kind: ShapeKind)

    /// Text sizes in points.
    public enum TextSize: String, CaseIterable {
        case small, normal, big
        public var points: CGFloat {
            switch self { case .small: return 16; case .normal: return 28; case .big: return 48 }
        }
    }

    /// Straight, or curving to one side.
    public enum ArrowStyle: String, CaseIterable { case right, normal, left }

    /// Outline shapes; `line` is a plain segment.
    public enum ShapeKind: String, CaseIterable { case rectangle, rounded, oval, line }
}

extension CaseIterable where Self: Equatable, AllCases.Index == Int {
    /// The next case, wrapping around: how repeating a tool's key cycles its variant.
    public var next: Self {
        let all = Array(Self.allCases)
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public enum Annotator {
    /// Markup colour: a strong red that reads on both light and dark screenshots.
    public static let color = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    static let strokeWidth: CGFloat = 4  // points

    public static func apply(_ annotations: [Annotation], to image: CGImage, scale: CGFloat) -> CGImage? {
        guard !annotations.isEmpty else { return image }
        guard let ctx = Bitmap.context(width: image.width, height: image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        // Flip so annotation coordinates (top-left origin) can be used directly.
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for annotation in annotations { draw(annotation, scale: scale) }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Draws into the current (flipped) graphics context. Also used for live previews.
    public static func draw(_ annotation: Annotation, scale: CGFloat) {
        switch annotation {
        case let .text(string, origin, size): drawText(string, at: origin, size: size, scale: scale)
        case let .arrow(from, to, style): drawArrow(from: from, to: to, style: style, scale: scale)
        case let .shape(from, to, kind): drawShape(from: from, to: to, kind: kind, scale: scale)
        }
    }

    /// Bounding box in capture pixels, for hit-testing and layout.
    public static func textSize(_ string: String, size: Annotation.TextSize, scale: CGFloat) -> CGSize {
        NSAttributedString(string: string, attributes: [.font: font(size, scale)]).size()
    }

    static func font(_ size: Annotation.TextSize, _ scale: CGFloat) -> NSFont {
        .systemFont(ofSize: size.points * scale, weight: .semibold)
    }

    // MARK: Text — coloured with a white outline and a soft drop shadow, legible on any background

    private static func drawText(_ string: String, at origin: CGPoint, size: Annotation.TextSize, scale: CGFloat) {
        let font = font(size, scale)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 8 * scale
        // Shadow offsets are in device space (y up), so -y is "down" like CSS's 3px 3px.
        shadow.shadowOffset = NSSize(width: 3 * scale, height: -3 * scale)
        let outline = NSAttributedString(string: string, attributes: [
            .font: font, .strokeColor: NSColor.white, .foregroundColor: NSColor.white,
            .strokeWidth: -(4 * scale / font.pointSize * 100),  // ≈ 2 pt of white each side
            .shadow: shadow,
        ])
        let fill = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        outline.draw(at: origin)
        fill.draw(at: origin)
    }

    // MARK: Arrow

    private static func drawArrow(from: CGPoint, to: CGPoint, style: Annotation.ArrowStyle, scale: CGFloat) {
        let width = strokeWidth * scale
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        // Curved styles bend the shaft sideways by a fifth of its length.
        let bend: CGFloat = style == .normal ? 0 : (style == .right ? 0.2 : -0.2) * length
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let control = CGPoint(x: mid.x - dy / length * bend, y: mid.y + dx / length * bend)

        // Head direction follows the curve's tangent at the tip.
        let angle = atan2(to.y - control.y, to.x - control.x)
        let headLength = max(width * 3.5, min(length * 0.35, width * 5))
        let headHalf = headLength * 0.55
        let base = CGPoint(x: to.x - cos(angle) * headLength * 0.8, y: to.y - sin(angle) * headLength * 0.8)

        let shaft = NSBezierPath()
        shaft.move(to: from)
        shaft.curve(to: base, controlPoint1: control, controlPoint2: control)
        shaft.lineWidth = width
        shaft.lineCapStyle = .round

        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: CGPoint(x: to.x - cos(angle) * headLength + sin(angle) * headHalf,
                              y: to.y - sin(angle) * headLength - cos(angle) * headHalf))
        head.line(to: CGPoint(x: to.x - cos(angle) * headLength - sin(angle) * headHalf,
                              y: to.y - sin(angle) * headLength + cos(angle) * headHalf))
        head.close()
        head.lineJoinStyle = .round
        head.lineWidth = width * 0.4

        withShadow(scale) {
            color.set()
            shaft.stroke()
            head.fill()
            head.stroke()
        }
    }

    // MARK: Shapes

    private static func drawShape(from: CGPoint, to: CGPoint, kind: Annotation.ShapeKind, scale: CGFloat) {
        let width = strokeWidth * scale
        let rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
        let path: NSBezierPath
        switch kind {
        case .rectangle: path = NSBezierPath(roundedRect: rect, xRadius: 2 * scale, yRadius: 2 * scale)
        case .rounded:
            let r = min(16 * scale, rect.width / 2, rect.height / 2)
            path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        case .oval: path = NSBezierPath(ovalIn: rect)
        case .line:
            path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineCapStyle = .round
        }
        path.lineWidth = width
        withShadow(scale) {
            color.setStroke()
            path.stroke()
        }
    }

    /// A faint dark edge so the markup colour reads on any background.
    private static func withShadow(_ scale: CGFloat, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2 * scale
        shadow.shadowOffset = .zero
        shadow.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}
