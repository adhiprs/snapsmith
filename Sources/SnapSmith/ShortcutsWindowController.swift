import AppKit
import CaptureKit

/// Settings for the global shortcuts, one recorder per action. Rejects combinations that
/// can't work: one SnapSmith already uses, a macOS screenshot shortcut, or one another app holds.
final class ShortcutsWindowController: NSWindowController {
    private var recorders: [ShortcutAction: ShortcutRecorderView] = [:]
    private var messages: [ShortcutAction: NSTextField] = [:]
    private weak var center: ShortcutCenter?

    init(center: ShortcutCenter) {
        self.center = center
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SnapSmith Shortcuts"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        refresh()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        var rows: [[NSView]] = []
        for action in ShortcutAction.allCases {
            let recorder = ShortcutRecorderView()
            recorder.onChange = { [weak self] shortcut in self?.apply(shortcut, to: action) ?? false }
            recorder.onRecordingChanged = { [weak self] recording in
                if recording { self?.show(nil, for: action) }
            }
            let reset = NSButton(title: "Default", target: self, action: #selector(resetOne(_:)))
            reset.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            reset.controlSize = .small
            reset.bezelStyle = .rounded
            let message = NSTextField(labelWithString: "")
            message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            message.textColor = .systemRed
            message.preferredMaxLayoutWidth = 170
            message.lineBreakMode = .byWordWrapping
            message.maximumNumberOfLines = 2
            recorders[action] = recorder
            messages[action] = message
            rows.append([NSTextField(labelWithString: action.title), recorder, reset, message])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 3).width = 170
        // Fixed row height (fits a two-line warning) so rows don't jump as warnings come and go.
        for row in 0..<grid.numberOfRows {
            grid.row(at: row).yPlacement = .center
            grid.row(at: row).height = 34
        }

        let note = NSTextField(wrappingLabelWithString: "Click a shortcut, then press the new keys (include ⌘, ⌥ or ⌃). Esc cancels, Delete turns the shortcut off. Shortcuts macOS already uses are refused. macOS can't tell SnapSmith about other apps' shortcuts, so if one doesn't respond, another app probably has it: pick a different one.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 500
        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))

        let stack = NSStackView(views: [grid, note, restore])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func refresh() {
        for action in ShortcutAction.allCases {
            recorders[action]?.shortcut = Preferences.shortcut(for: action)
            show(center?.unavailable.contains(action) == true ? "Couldn't be registered — pick another" : nil, for: action)
        }
    }

    private func show(_ message: String?, for action: ShortcutAction) {
        messages[action]?.stringValue = message ?? ""
    }

    /// Validates and saves. Returning false keeps the recorder's previous shortcut.
    private func apply(_ shortcut: Shortcut?, to action: ShortcutAction) -> Bool {
        if let shortcut {
            if let other = ShortcutAction.allCases.first(where: { $0 != action && Preferences.shortcut(for: $0) == shortcut }) {
                show("Already used for \(other.title)", for: action)
                return false
            }
            if shortcut.isSystemScreenshotShortcut {
                show("macOS uses \(shortcut.displayString) for its own screenshots", for: action)
                return false
            }
            if shortcut.isReservedBySystem {
                show("macOS already uses \(shortcut.displayString) (Keyboard Shortcuts settings)", for: action)
                return false
            }
        }
        Preferences.setShortcut(shortcut, for: action)
        show(nil, for: action)
        return true
    }

    @objc private func resetOne(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = ShortcutAction(rawValue: raw) else { return }
        window?.makeFirstResponder(nil)
        // The default may now clash with another action's custom shortcut; check like any other.
        NotificationCenter.default.post(name: ShortcutCenter.pauseRequested, object: nil)
        if apply(action.defaultShortcut, to: action) { recorders[action]?.shortcut = action.defaultShortcut }
        NotificationCenter.default.post(name: ShortcutCenter.resumeRequested, object: nil)
    }

    @objc private func restoreDefaults() {
        window?.makeFirstResponder(nil)
        Preferences.resetShortcuts()
        refresh()
    }
}
