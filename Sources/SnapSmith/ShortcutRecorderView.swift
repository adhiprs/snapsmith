import AppKit
import Carbon.HIToolbox
import CaptureKit

/// Click, then press a key combination. Esc cancels,
/// Delete clears. While recording, SnapSmith's global hotkeys are paused.
final class ShortcutRecorderView: NSView {
    var shortcut: Shortcut? { didSet { needsDisplay = true } }
    /// Return false to reject the shortcut (the caller shows why); the old one is kept.
    var onChange: ((Shortcut?) -> Bool)?
    var onRecordingChanged: ((Bool) -> Void)?

    private(set) var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            NotificationCenter.default.post(name: isRecording ? ShortcutCenter.pauseRequested : ShortcutCenter.resumeRequested,
                                            object: nil)
            onRecordingChanged?(isRecording)
            needsDisplay = true
        }
    }
    private var liveModifiers: NSEvent.ModifierFlags = []

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            window?.makeFirstResponder(nil)
        } else {
            window?.makeFirstResponder(self)
            isRecording = true
        }
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        liveModifiers = []
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { isRecording = false }  // never leave the hotkeys paused
        super.viewWillMove(toWindow: newWindow)
    }

    /// ⌘-combinations arrive here (before menus claim them) rather than in keyDown.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        record(event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }
        liveModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        needsDisplay = true
    }

    private func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (Int(event.keyCode), flags.isEmpty) {
        case (kVK_Escape, true):
            window?.makeFirstResponder(nil)  // cancel
        case (kVK_Delete, true), (kVK_ForwardDelete, true):
            if onChange?(nil) ?? true { shortcut = nil }
            window?.makeFirstResponder(nil)
        default:
            let recorded = Shortcut(keyCode: Int(event.keyCode), modifiers: Self.carbonModifiers(flags))
            guard recorded.isValid else { return NSSound.beep() }  // keep listening for a real combination
            if onChange?(recorded) ?? true { shortcut = recorded }
            window?.makeFirstResponder(nil)
        }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            let partial = Shortcut.modifierSymbols(UInt32(Self.carbonModifiers(liveModifiers)))
            text = partial.isEmpty ? "Type shortcut…" : partial + "…"
            color = .controlAccentColor
        } else if let shortcut {
            text = shortcut.displayString
            color = .labelColor
        } else {
            text = "Click to record"
            color = .placeholderTextColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: isRecording || shortcut == nil ? .regular : .medium),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
