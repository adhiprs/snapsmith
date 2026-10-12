import AppKit

/// Markup drawn on top of a capture. Points are capture pixels with a top-left origin; sizes
/// are in points and are multiplied by the capture's scale when drawn. Each item carries its
/// own colour, so changing the colour later doesn't recolour what's already drawn.
public enum Annotation: Equatable {
    case text(String, origin: CGPoint, size: CGFloat, look: TextLook, color: NSColor)
    case arrow(from: CGPoint, to: CGPoint, style: ArrowStyle, color: NSColor)
    case shape(from: CGPoint, to: CGPoint, kind: ShapeKind, color: NSColor)

    /// `label` puts white text on a filled rounded label; `plain` is coloured text with a soft shadow.
    public enum TextLook: String, CaseIterable {
        case label, plain
        public var title: String { self == .label ? "Label" : "Plain text" }
    }

    public enum ArrowStyle: String, CaseIterable {
        case pointer   // straight, solid head
        case open      // straight, open "V" head
        case curved    // gentle arc, solid head
        case double    // straight, a head at both ends
        public var title: String {
            switch self {
            case .pointer: return "Pointer"
            case .open: return "Open head"
            case .curved: return "Curved"
            case .double: return "Double-headed"
            }
        }
    }

    public enum ShapeKind: String, CaseIterable {
        case box, ellipse, highlight, line
        public var title: String {
            switch self {
            case .box: return "Box"
            case .ellipse: return "Ellipse"
            case .highlight: return "Highlight"
            case .line: return "Line"
            }
        }
    }
}

/// Quick text sizes in points; the editor also offers a free size slider.
public enum TextSizePreset: String, CaseIterable {
    case small, medium, large
    public var points: CGFloat {
        switch self { case .small: return 14; case .medium: return 24; case .large: return 40 }
    }
    public var title: String {
        switch self { case .small: return "S"; case .medium: return "M"; case .large: return "L" }
    }
}

extension CaseIterable where Self: Equatable, AllCases.Index == Int {
    /// The next case, wrapping around: how a tool's variant is cycled from the keyboard.
    public var next: Self {
        let all = Array(Self.allCases)
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

public enum Annotator {
    /// Default markup colour: a warm vermilion that reads on light and dark screenshots.
    public static let defaultColor = NSColor(srgbRed: 1, green: 0.35, blue: 0.21, alpha: 1)
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
        case let .text(string, origin, size, look, color):
            drawText(string, at: origin, size: size, look: look, color: color, scale: scale)
        case let .arrow(from, to, style, color):
            drawArrow(from: from, to: to, style: style, color: color, scale: scale)
        case let .shape(from, to, kind, color):
            drawShape(from: from, to: to, kind: kind, color: color, scale: scale)
        }
    }

    // MARK: Text

    static func font(_ points: CGFloat, _ scale: CGFloat) -> NSFont {
        .systemFont(ofSize: points * scale, weight: .semibold)
    }

    /// Size in capture pixels of the text itself (without a label's padding).
    public static func textSize(_ string: String, points: CGFloat, scale: CGFloat) -> CGSize {
        NSAttributedString(string: string, attributes: [.font: font(points, scale)]).size()
    }

    /// Label padding in pixels around the text.
    static func labelPadding(_ points: CGFloat, _ scale: CGFloat) -> CGSize {
        CGSize(width: points * 0.55 * scale, height: points * 0.3 * scale)
    }

    private static func drawText(_ string: String, at origin: CGPoint, size points: CGFloat,
                                 look: Annotation.TextLook, color: NSColor, scale: CGFloat) {
        let font = font(points, scale)
        switch look {
        case .label:
            let text = NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: readableTextColor(on: color),
            ])
            let pad = labelPadding(points, scale)
            let box = CGRect(x: origin.x, y: origin.y, width: text.size().width + pad.width * 2,
                             height: text.size().height + pad.height * 2)
            withShadow(scale, blur: 6, alpha: 0.25, offset: 2) {
                color.setFill()
                NSBezierPath(roundedRect: box, xRadius: box.height * 0.28, yRadius: box.height * 0.28).fill()
            }
            text.draw(at: NSPoint(x: box.minX + pad.width, y: box.minY + pad.height))
        case .plain:
            let text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
            withShadow(scale, blur: 5, alpha: 0.45, offset: 1.5) { text.draw(at: origin) }
        }
    }

    /// White text on most colours, dark text on very light ones.
    public static func readableTextColor(on color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luminance > 0.72 ? NSColor(white: 0.1, alpha: 1) : .white
    }

    // MARK: Arrows

    private static func drawArrow(from: CGPoint, to: CGPoint, style: Annotation.ArrowStyle,
                                  color: NSColor, scale: CGFloat) {
        let width = strokeWidth * scale
        let dx = to.x - from.x, dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }

        // The curved style bends the shaft sideways by a fifth of its length.
        let bend: CGFloat = style == .curved ? 0.2 * length : 0
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let control = CGPoint(x: mid.x - dy / length * bend, y: mid.y + dx / length * bend)

        let headLength = min(max(width * 3.6, length * 0.12), width * 6)
        let tipAngle = atan2(to.y - control.y, to.x - control.x)
        let tailAngle = atan2(from.y - control.y, from.x - control.x)
        let solid = style != .open
        let doubleEnded = style == .double

        func inset(_ point: CGPoint, _ angle: CGFloat, _ amount: CGFloat) -> CGPoint {
            CGPoint(x: point.x - cos(angle) * amount, y: point.y - sin(angle) * amount)
        }
        // Stop the shaft short of solid heads so its round cap doesn't poke through the tip.
        let shaftEnd = solid ? inset(to, tipAngle, headLength * 0.7) : to
        let shaftStart = doubleEnded ? inset(from, tailAngle, headLength * 0.7) : from

        let shaft = NSBezierPath()
        shaft.move(to: shaftStart)
        shaft.curve(to: shaftEnd, controlPoint1: control, controlPoint2: control)
        shaft.lineWidth = width
        shaft.lineCapStyle = .round

        withShadow(scale, blur: 3, alpha: 0.3, offset: 0) {
            color.set()
            shaft.stroke()
            head(at: to, angle: tipAngle, length: headLength, solid: solid, width: width)
            if doubleEnded { head(at: from, angle: tailAngle, length: headLength, solid: true, width: width) }
        }
    }

    /// An arrow head with its tip at `point`, pointing along `angle`.
    private static func head(at point: CGPoint, angle: CGFloat, length: CGFloat, solid: Bool, width: CGFloat) {
        let half = length * 0.55
        let left = CGPoint(x: point.x - cos(angle) * length + sin(angle) * half,
                           y: point.y - sin(angle) * length - cos(angle) * half)
        let right = CGPoint(x: point.x - cos(angle) * length - sin(angle) * half,
                            y: point.y - sin(angle) * length + cos(angle) * half)
        let path = NSBezierPath()
        if solid {
            path.move(to: point)
            path.line(to: left)
            path.line(to: right)
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = width * 0.4
            path.fill()
            path.stroke()
        } else {
            path.move(to: left)
            path.line(to: point)
            path.line(to: right)
            path.lineWidth = width
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    // MARK: Shapes

    private static func drawShape(from: CGPoint, to: CGPoint, kind: Annotation.ShapeKind,
                                  color: NSColor, scale: CGFloat) {
        let width = strokeWidth * scale
        let rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
        let path: NSBezierPath
        switch kind {
        case .box:
            let r = min(8 * scale, rect.width / 2, rect.height / 2)
            path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        case .ellipse:
            path = NSBezierPath(ovalIn: rect)
        case .highlight:
            let r = min(6 * scale, rect.width / 2, rect.height / 2)
            path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        case .line:
            path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineCapStyle = .round
        }
        path.lineWidth = width
        if kind == .highlight {
            color.withAlphaComponent(0.3).setFill()
            path.fill()
            return
        }
        withShadow(scale, blur: 3, alpha: 0.3, offset: 0) {
            color.setStroke()
            path.stroke()
        }
    }

    /// A soft dark shadow, in points, so markup reads on any background.
    private static func withShadow(_ scale: CGFloat, blur: CGFloat, alpha: CGFloat, offset: CGFloat, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur * scale
        // Shadow offsets are in device space (y up), so a negative y moves it down on screen.
        shadow.shadowOffset = NSSize(width: offset * scale, height: -offset * scale)
        shadow.set()
        body()
        NSGraphicsContext.restoreGraphicsState()
    }
}
