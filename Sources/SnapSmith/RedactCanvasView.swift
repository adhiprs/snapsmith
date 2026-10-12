import AppKit
import Carbon.HIToolbox
import CaptureKit

/// The editing tools. Their keys depend on the user's `ToolKeyScheme`.
enum EditTool: Int, CaseIterable {
    case text = 1, arrow, redact, shape

    var title: String {
        switch self {
        case .text: return "Text"
        case .arrow: return "Arrow"
        case .redact: return "Redact"
        case .shape: return "Box"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "textformat"
        case .arrow: return "arrow.up.right"
        case .redact: return "eye.slash"
        case .shape: return "square"
        }
    }

    /// The key that selects this tool: "T", "A", "R", "B" or "1"–"4".
    func key(_ scheme: ToolKeyScheme) -> String {
        switch scheme {
        case .numbers: return "\(rawValue)"
        case .letters:
            switch self {
            case .text: return "T"
            case .arrow: return "A"
            case .redact: return "R"
            case .shape: return "B"
            }
        }
    }

    /// The tool a key press selects, and whether Shift was held (which cycles its variant).
    /// Letters follow the typed character, so they work on other layouts; numbers use the
    /// number row's key codes, since Shift changes the character they type.
    static func from(event: NSEvent, scheme: ToolKeyScheme) -> (tool: EditTool, shift: Bool)? {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let shift = event.modifierFlags.contains(.shift)
        switch scheme {
        case .numbers:
            let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]
            guard let index = codes.firstIndex(of: Int(event.keyCode)) else { return nil }
            return (EditTool(rawValue: index + 1)!, shift)
        case .letters:
            guard let character = event.charactersIgnoringModifiers?.lowercased(),
                  let tool = allCases.first(where: { $0.key(.letters).lowercased() == character })
            else { return nil }
            return (tool, shift)
        }
    }
}

/// The preview's image view. With a tool active it reports clicks and drags in capture
/// pixels (top-left origin) and draws live feedback; in redact mode it also outlines every
/// clickable word.
final class RedactCanvasView: NSImageView {
    var tool: EditTool? {
        didSet {
            hovered = nil
            dragStart = nil
            dragCurrent = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var isEditing: Bool { tool != nil }
    /// Pixel size and scale of the capture being edited (the displayed image while editing).
    var capturePixelSize: CGSize = .zero
    var captureScale: CGFloat = 1
    /// Clickable boxes in capture pixels (redact mode): words plus current redactions.
    var targets: [CGRect] = [] { didSet { needsDisplay = true } }
    var onClick: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint, CGPoint) -> Void)?
    /// Builds the annotation to preview while dragging (arrow and shape tools).
    var dragPreview: ((CGPoint, CGPoint) -> Annotation?)?

    private var hovered: CGRect?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var tracking: NSTrackingArea?

    // MARK: Geometry

    /// Where the image is drawn inside the view: aspect fit, scaled up or down, centred
    /// (matches `.scaleProportionallyUpOrDown`).
    private var imageFrame: NSRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return .zero }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let drawn = NSSize(width: size.width * fit, height: size.height * fit)
        return NSRect(x: bounds.midX - drawn.width / 2, y: bounds.midY - drawn.height / 2,
                      width: drawn.width, height: drawn.height)
    }

    /// View points per capture pixel.
    var viewScale: CGFloat {
        capturePixelSize.width > 0 ? imageFrame.width / capturePixelSize.width : 1
    }

    func toCapture(_ point: NSPoint) -> CGPoint {
        let frame = imageFrame
        return CGPoint(x: (point.x - frame.minX) / frame.width * capturePixelSize.width,
                       y: (frame.maxY - point.y) / frame.height * capturePixelSize.height)
    }

    func toView(_ point: CGPoint) -> NSPoint {
        let frame = imageFrame
        return NSPoint(x: frame.minX + point.x * viewScale, y: frame.maxY - point.y * viewScale)
    }

    private func toView(_ rect: CGRect) -> NSRect {
        let s = viewScale, frame = imageFrame
        return NSRect(x: frame.minX + rect.minX * s, y: frame.maxY - rect.maxY * s,
                      width: rect.width * s, height: rect.height * s)
    }

    // MARK: Mouse

    /// While editing, the first click on an inactive window should act, not just focus it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isEditing }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        guard let tool else { return }
        addCursorRect(imageFrame, cursor: tool == .text ? .iBeam : .crosshair)
    }

    override func mouseMoved(with event: NSEvent) {
        guard tool == .redact else { return }
        let point = toCapture(convert(event.locationInWindow, from: nil))
        let hit = targets.last { $0.insetBy(dx: -2, dy: -2).contains(point) }
        if hit != hovered { hovered = hit; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEditing else { return super.mouseDown(with: event) }
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEditing, dragStart != nil, tool != .text else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isEditing, let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
        // More than 5 pt each way counts as a drag; anything less is a click.
        // Lines and arrows can be flat, so for them distance counts instead.
        let moved = (tool == .arrow || tool == .shape)
            ? hypot(end.x - start.x, end.y - start.y) > 5
            : abs(end.x - start.x) > 5 && abs(end.y - start.y) > 5
        if moved, tool != .text {
            onDrag?(toCapture(start), toCapture(end))
        } else {
            onClick?(toCapture(end))
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let tool, capturePixelSize.width > 0 else { return }

        if tool == .redact {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
            for target in targets {
                let path = NSBezierPath(roundedRect: toView(target).insetBy(dx: -1, dy: -1), xRadius: 2, yRadius: 2)
                path.lineWidth = 1
                path.stroke()
            }
            if let hovered {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                let path = NSBezierPath(roundedRect: toView(hovered).insetBy(dx: -2, dy: -2), xRadius: 3, yRadius: 3)
                path.fill()
                NSColor.controlAccentColor.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
        }

        guard let start = dragStart, let current = dragCurrent, hypot(current.x - start.x, current.y - start.y) > 5 else { return }
        if tool == .redact {
            NSColor.black.withAlphaComponent(0.5).setFill()  // in-progress boxes are semi-transparent
            NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                   width: abs(current.x - start.x), height: abs(current.y - start.y)).fill()
        } else if let annotation = dragPreview?(toCapture(start), toCapture(current)) {
            // Draw in capture coordinates: map them onto the view, flipped to top-left origin.
            NSGraphicsContext.saveGraphicsState()
            let frame = imageFrame
            let transform = NSAffineTransform()
            transform.translateX(by: frame.minX, yBy: frame.maxY)
            transform.scaleX(by: viewScale, yBy: -viewScale)
            transform.concat()
            NSGraphicsContext.current?.cgContext.setAlpha(0.6)  // previews are semi-transparent
            Annotator.draw(annotation, scale: captureScale)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
