import AppKit
import CaptureKit
import Carbon.HIToolbox
import ServiceManagement

/// Menu-bar app. Default shortcuts (changeable in Shortcuts…): ⌥⇧4 captures an area, ⌥⇧5 a
/// window, ⌥⇧3 captures an area and copies it straight away, ⌥⇧2 copies the text in an area.
/// Area and window captures open the preview window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let capturer = ScreenCapturer()
    private var statusItem: NSStatusItem!
    private var shortcutCenter: ShortcutCenter!
    private var shortcutItems: [ShortcutAction: NSMenuItem] = [:]
    private var shortcutsWindow: ShortcutsWindowController?
    private var isCapturing = false
    private var beautifyItem: NSMenuItem!
    private var styleWindow: StyleWindowController?
    private lazy var previewWindow: PreviewWindowController = {
        let preview = PreviewWindowController()
        preview.onCopied = { [weak self] in self?.flashStatusIcon("checkmark.circle.fill") }
        preview.onOpenStyle = { [weak self] in self?.openStyleWindow() }
        return preview
    }()
    private var loginItem: NSMenuItem?
    private var cleanupTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder",
                                           accessibilityDescription: "SnapSmith")

        let menu = NSMenu()
        let actions: [(ShortcutAction, Selector)] = [(.captureArea, #selector(captureArea)), (.captureWindow, #selector(captureWindow)),
                                                     (.captureAndCopy, #selector(captureAndCopy)), (.captureText, #selector(captureText))]
        for (action, selector) in actions {
            shortcutItems[action] = menu.addItem(withTitle: action.title, action: selector, keyEquivalent: "")
        }
        menu.addItem(.separator())
        beautifyItem = menu.addItem(withTitle: "Beautify Captures", action: #selector(toggleBeautify), keyEquivalent: "")
        beautifyItem.state = Preferences.beautify() ? .on : .off
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.beautifyItem.state = Preferences.beautify() ? .on : .off
        }
        menu.addItem(withTitle: "Style Settings…", action: #selector(openStyleWindow), keyEquivalent: ",")
        menu.addItem(withTitle: "Shortcuts…", action: #selector(openShortcutsWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Archive Folder", action: #selector(openArchive), keyEquivalent: "")
        menu.addItem(withTitle: "Screen Recording Settings…", action: #selector(openSettings), keyEquivalent: "")
        if #available(macOS 13, *), Bundle.main.bundleIdentifier != nil {
            // Login items need a real .app bundle (scripts/bundle.sh).
            loginItem = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
            loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        shortcutCenter = ShortcutCenter(handlers: [
            .captureArea: { [weak self] in self?.captureArea() },
            .captureWindow: { [weak self] in self?.captureWindow() },
            .captureAndCopy: { [weak self] in self?.captureAndCopy() },
            .captureText: { [weak self] in self?.captureText() },
        ])
        updateShortcutMenuItems()
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateShortcutMenuItems()
        }

        if !ScreenCapturer.hasScreenRecordingPermission() {
            ScreenCapturer.requestScreenRecordingPermission()
        }

        // Archive retention: on launch, hourly while running, and when the setting changes.
        cleanArchive()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.cleanArchive() }
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.cleanArchive()
        }
    }

    /// Shows each action's current shortcut in the menu, the standard macOS way.
    private func updateShortcutMenuItems() {
        for (action, item) in shortcutItems {
            let shortcut = Preferences.shortcut(for: action)
            if let shortcut, let character = shortcut.keyCharacter {
                item.title = action.title
                item.keyEquivalent = character.lowercased()
                item.keyEquivalentModifierMask = Self.menuModifiers(shortcut.modifiers)
            } else {
                // Keys without a character (F-keys, arrows) go in the title instead.
                item.keyEquivalent = ""
                item.title = shortcut.map { "\(action.title)  \($0.displayString)" } ?? action.title
            }
        }
    }

    private static func menuModifiers(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    @objc private func openShortcutsWindow() {
        if shortcutsWindow == nil { shortcutsWindow = ShortcutsWindowController(center: shortcutCenter) }
        shortcutsWindow?.present()
    }

    /// Moves captures older than the retention setting to the Trash (SnapSmith's own archive only).
    private func cleanArchive() {
        guard let days = Preferences.archiveRetentionDays() else { return }
        let root = capturer.archiveDirectory.deletingLastPathComponent()  // Archives/, holding Originals and Edited
        DispatchQueue.global(qos: .utility).async {
            let removed = ArchiveCleaner.clean(root, olderThan: days)
            if !removed.isEmpty { NSLog("SnapSmith: moved \(removed.count) capture(s) older than \(days) days to the Trash") }
        }
    }

    @objc private func captureArea() { run(.interactive) { [weak self] in self?.finishImage($0) } }
    @objc private func captureWindow() { run(.window) { [weak self] in self?.finishImage($0) } }
    @objc private func captureText() { run(.interactive) { [weak self] in self?.finishText($0) } }
    @objc private func captureAndCopy() { run(.interactive) { [weak self] in self?.finishQuickCopy($0) } }

    /// Capture & Copy: no preview, saved settings applied.
    private func finishQuickCopy(_ raw: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Pipeline.quickOutput(forRaw: raw) }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let url):
                    ScreenCapturer.copyToClipboard(url)
                    self?.flashStatusIcon("checkmark.circle.fill")
                    NSLog("SnapSmith: copied \(url.path)")
                case .failure(let error):
                    // Never fall back to copying an unredacted capture.
                    self?.flashStatusIcon("exclamationmark.triangle.fill")
                    let alert = NSAlert()
                    alert.messageText = "Capture not copied"
                    alert.informativeText = "SnapSmith couldn't scan it for sensitive text: \(error.localizedDescription)"
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }
    }

    @objc private func toggleBeautify() {
        Preferences.setBeautify(!Preferences.beautify())
    }

    /// Hidden for a menu-bar app, but its key equivalents (⌘C, ⌘V, ⌘W, ⌘Q…) still work
    /// in our windows, including the Save panel's name field.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        }
        submenu("SnapSmith", [NSMenuItem(title: "Quit SnapSmith", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")])
        submenu("File", [NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        submenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"), redo,
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ])
        return main
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("SnapSmith: login item change failed: \(error)")
        }
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Briefly swaps the menu bar icon so the user knows the capture landed.
    private func flashStatusIcon(_ symbol: String) {
        let original = statusItem.button?.image
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.statusItem.button?.image = original
        }
    }

    @objc private func openStyleWindow() {
        if styleWindow == nil { styleWindow = StyleWindowController(archiveDirectory: capturer.archiveDirectory) }
        styleWindow?.present()
    }

    private func finishImage(_ raw: URL) {
        NSLog("SnapSmith: saved \(raw.path)")
        previewWindow.show(raw: raw)
    }

    private func finishText(_ raw: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = Beautifier.loadImage(raw).flatMap { try? TextRecognizer.recognizeText(in: $0) } ?? ""
            DispatchQueue.main.async { [weak self] in
                guard !text.isEmpty else {
                    self?.flashStatusIcon("text.badge.xmark")
                    return NSLog("SnapSmith: no text found")
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self?.flashStatusIcon("text.badge.checkmark")
                NSLog("SnapSmith: copied \(text.count) characters of text")
            }
        }
    }

    private func run(_ mode: CaptureMode, then finish: @escaping (URL) -> Void) {
        guard !isCapturing else { return }  // a second screencapture would fight the first
        isCapturing = true
        // Keep our own windows out of the shot.
        let hiddenWindows = [styleWindow?.window, previewWindow.window].compactMap { $0 }.filter(\.isVisible)
        hiddenWindows.forEach { $0.orderOut(nil) }
        capturer.capture(CaptureOptions(mode: mode)) { [weak self] result in
            self?.isCapturing = false
            self?.cleanArchive()
            hiddenWindows.forEach { $0.orderFront(nil) }
            switch result {
            case .success(.captured(let url)):
                finish(url)
            case .success(.cancelled):
                NSLog("SnapSmith: screenshot cancelled")
            case .failure(.permissionDenied):
                self?.showPermissionAlert()
            case .failure(let error):
                NSLog("SnapSmith: capture failed: \(error)")
            }
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
            1. Click Open Settings and turn on SnapSmith under Screen Recording.
            2. Come back and click Relaunch. macOS only applies the permission after a restart of the app.

            If SnapSmith is already on there but this keeps appearing, the entry belongs to an \
            older build: select it, remove it with −, and try again.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: ScreenCapturer.openScreenRecordingSettings()
        case .alertSecondButtonReturn: relaunch()
        default: break
        }
    }

    /// Starts a fresh copy once this one has exited, so the new permission is picked up.
    private func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return NSApp.terminate(nil) }  // `swift run`: nothing to reopen
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", path]
        try? reopen.run()
        NSApp.terminate(nil)
    }

    @objc private func openArchive() {
        // Open Archives/ rather than Archives/Originals so Originals and Edited are both visible.
        try? FileManager.default.createDirectory(at: capturer.archiveDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(capturer.archiveDirectory.deletingLastPathComponent())
    }

    @objc private func openSettings() { ScreenCapturer.openScreenRecordingSettings() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
