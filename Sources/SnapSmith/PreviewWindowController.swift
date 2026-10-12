import AppKit
import CaptureKit
import UniformTypeIdentifiers

/// Shown after every image capture: preview the result, mark it up,
/// tweak the common options, then Copy (⌘C) or Save. Closes after copying when "Close after
/// copy" is on (the default).
///
/// Tools use the number keys: 1 text, 2 arrow, 3 redact, 4 shape; pressing a tool's key again
/// cycles its variant (text size, arrow style, shape). Text is read once per capture (OCR is
/// the slow part) for auto-redact matches and the clickable words in redact mode.
/// Rendering order: redact → annotations → beautify. With auto-redact on, Copy/Save wait for
/// the scan, so an unredacted image never reaches the clipboard.
final class PreviewWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate {
    var onCopied: (() -> Void)?
    var onOpenStyle: (() -> Void)?

    private var raw: URL?
    private var source: CGImage?
    private var scale: CGFloat = 1
    private var style = StyleStore.load()

    private let imageView = RedactCanvasView()
    private let beautify = NSButton(checkboxWithTitle: "Beautify", target: nil, action: nil)
    private let inset = NSButton(checkboxWithTitle: "Inset", target: nil, action: nil)
    private let padding = NSSlider(value: 0, minValue: 0, maxValue: 128, target: nil, action: nil)
    private let paddingLabel = NSTextField(labelWithString: "Padding")
    private let closeAfterCopy = NSButton(checkboxWithTitle: "Close after copy", target: nil, action: nil)
    private let redact = NSButton(checkboxWithTitle: "Redact", target: nil, action: nil)
    private let redactStatus = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)

    private let tools = NSSegmentedControl()
    /// Instructions shown over the image while a tool is active.
    private let editHint = NSVisualEffectView()
    private let hintLabel = NSTextField(labelWithString: "")

    // Redaction state (per capture)
    private var lines: [TextLine]?
    private var words: [RedactRegion] = []
    private var edits = RedactionEdits()
    private let scanQueue = DispatchQueue(label: "snapsmith.redact-scan")
    private var scanGeneration = 0
    private var isScanning = false

    // Annotation state (per capture); tool variants persist across captures
    private var annotations: [Annotation] = []
    private var tool: EditTool?
    private var textSize: Annotation.TextSize = .normal
    private var arrowStyle: Annotation.ArrowStyle = .normal
    private var shapeKind: Annotation.ShapeKind = .rectangle
    private var activeText: (field: NSTextField, origin: CGPoint)?

    /// Undo stack of earlier (annotations, redaction edits) states.
    private var history: [([Annotation], RedactionEdits)] = []

    private let renderQueue = DispatchQueue(label: "snapsmith.capture-preview")
    private var renderGeneration = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "SnapSmith"
        window.isReleasedWhenClosed = false
        window.level = .floating  // stay above the app that was just captured
        window.minSize = NSSize(width: 900, height: 400)
        super.init(window: window)
        window.delegate = self
        buildToolbar()
        buildUI()

        // Keep in sync with the Style window and the menu.
        for name in [StyleStore.didChange, Preferences.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reloadSettings()
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Shows a new capture, replacing whatever the window was showing.
    func show(raw: URL) {
        guard let image = Beautifier.loadImage(raw) else { return }
        cancelText()
        self.raw = raw
        source = image
        scale = Beautifier.scale(of: raw)
        lines = nil
        words = []
        edits = RedactionEdits()
        annotations = []
        history = []
        setTool(nil)
        window?.title = raw.lastPathComponent
        reloadSettings()
        sizeWindowToFit(image)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private static let toolsItem = NSToolbarItem.Identifier("tools")
    private static let undoItem = NSToolbarItem.Identifier("undo")

    private func buildToolbar() {
        tools.segmentCount = EditTool.allCases.count
        tools.trackingMode = .selectOne
        for tool in EditTool.allCases {
            let index = tool.rawValue - 1
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: index)
            tools.setLabel("\(tool.title) \(tool.rawValue)", forSegment: index)
            tools.setToolTip("\(tool.title) (\(tool.rawValue))" + (tool == .redact ? "" : " — press again to change style"),
                             forSegment: index)
        }
        tools.target = self
        tools.action = #selector(toolClicked)

        let toolbar = NSToolbar(identifier: "SnapSmithPreview")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.toolsItem, .flexibleSpace, Self.undoItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.toolsItem:
            item.view = tools
            item.label = "Tools"
        case Self.undoItem:
            let button = NSButton(image: NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")!,
                                  target: self, action: #selector(undo(_:)))
            button.bezelStyle = .texturedRounded
            button.toolTip = "Undo (⌘Z)"
            item.view = button
            item.label = "Undo"
        default:
            return nil
        }
        return item
    }

    private func buildUI() {
        guard let window, let content = window.contentView else { return }

        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Weakest possible: the image view absorbs whatever space the bar leaves.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imageView.setContentCompressionResistancePriority(.init(1), for: orientation)
            imageView.setContentHuggingPriority(.init(1), for: orientation)
        }
        imageView.onClick = { [weak self] point in self?.clicked(at: point) }
        imageView.onDrag = { [weak self] from, to in self?.dragged(from: from, to: to) }
        imageView.dragPreview = { [weak self] from, to in self?.annotation(from: from, to: to) }

        for control in [beautify, inset, closeAfterCopy, redact] {
            control.target = self
            control.action = #selector(optionChanged)
        }
        padding.target = self
        padding.action = #selector(optionChanged)
        padding.isContinuous = true
        padding.widthAnchor.constraint(equalToConstant: 90).isActive = true
        redactStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        redactStatus.textColor = .secondaryLabelColor
        redactStatus.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true

        let styleButton = NSButton(title: "Style…", target: self, action: #selector(openStyle))
        // Esc is handled in keyDown/cancelOperation so it can mean "leave the tool" first.
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.toolTip = "Close (Esc)"
        let saveButton = NSButton(title: "Save…", target: self, action: #selector(save))
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = .command
        copyButton.target = self
        copyButton.action = #selector(copyImage)
        copyButton.keyEquivalent = "\r"  // Return; ⌘C arrives via copy(_:)
        copyButton.toolTip = "Copy (⌘C or Return)"

        let left = NSStackView(views: [beautify, inset, paddingLabel, padding, redact, redactStatus])
        left.spacing = 12
        left.setCustomSpacing(20, after: padding)
        left.setCustomSpacing(4, after: redact)
        let right = NSStackView(views: [closeAfterCopy, styleButton, closeButton, saveButton, copyButton])
        right.spacing = 8

        // Gravity areas push the two groups to opposite edges without a stretchy spacer view.
        let bar = NSStackView()
        bar.addView(left, in: .leading)
        bar.addView(right, in: .trailing)
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        // NSStackView's own hugging (not contentHugging): keep the bar exactly as tall as
        // its controls so the image view gets all the spare height.
        bar.setHuggingPriority(.defaultHigh, for: .vertical)

        hintLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        editHint.material = .hudWindow
        editHint.state = .active
        editHint.wantsLayer = true
        editHint.layer?.cornerRadius = 8
        editHint.isHidden = true
        editHint.addSubview(hintLabel)

        let background = NSVisualEffectView()
        background.material = .underWindowBackground

        for view in [background, imageView, bar, editHint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        // The content layout guide excludes the title bar and toolbar.
        let top = (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? content.topAnchor
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: top, constant: 8),
            imageView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: editHint.leadingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: editHint.trailingAnchor, constant: -12),
            hintLabel.topAnchor.constraint(equalTo: editHint.topAnchor, constant: 6),
            hintLabel.bottomAnchor.constraint(equalTo: editHint.bottomAnchor, constant: -6),
            editHint.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            editHint.topAnchor.constraint(equalTo: imageView.topAnchor, constant: 8),
        ])
    }

    /// Fits the capture's aspect ratio inside a comfortable on-screen size.
    private func sizeWindowToFit(_ image: CGImage) {
        guard let window, let screen = NSScreen.main?.visibleFrame else { return }
        let chrome = NSSize(width: 32, height: 60 + 56)  // title bar + toolbar, bottom bar
        let maxImage = NSSize(width: min(1000, screen.width * 0.7) - chrome.width,
                              height: min(720, screen.height * 0.75) - chrome.height)
        let pointSize = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let fit = min(1, maxImage.width / pointSize.width, maxImage.height / pointSize.height)
        let size = NSSize(width: max(window.minSize.width, pointSize.width * fit + chrome.width),
                          height: max(window.minSize.height, pointSize.height * fit + chrome.height))
        window.setContentSize(size)
        window.center()
    }

    // MARK: - Settings

    private func reloadSettings() {
        style = StyleStore.load()
        beautify.state = Preferences.beautify() ? .on : .off
        inset.state = style.inset == nil ? .off : .on
        padding.doubleValue = Double(style.padding)
        closeAfterCopy.state = Preferences.closeAfterCopy() ? .on : .off
        redact.state = Preferences.autoRedact() ? .on : .off
        let styled = beautify.state == .on
        inset.isEnabled = styled
        padding.isEnabled = styled
        paddingLabel.textColor = styled ? .labelColor : .disabledControlTextColor
        if Preferences.autoRedact() || tool == .redact { startScanIfNeeded() }
        updateRedactStatus()
        renderPreview()
    }

    @objc private func optionChanged(_ sender: NSControl) {
        // Edits here are sticky: they become the defaults for the next capture.
        switch sender {
        case beautify:
            Preferences.setBeautify(beautify.state == .on)
        case closeAfterCopy:
            Preferences.setCloseAfterCopy(closeAfterCopy.state == .on)
        case redact:
            Preferences.setAutoRedact(redact.state == .on)
        default:
            var updated = StyleStore.load()
            updated.padding = CGFloat(padding.doubleValue.rounded())
            updated.inset = inset.state == .on ? (updated.inset ?? 20) : nil
            StyleStore.save(updated)
        }
        // Each setter posts a change notification, which calls reloadSettings().
    }

    // MARK: - Tools

    @objc private func toolClicked() {
        selectTool(EditTool(rawValue: tools.selectedSegment + 1))
    }

    /// Choosing the active tool again cycles its variant (as pressing its key twice does).
    private func selectTool(_ chosen: EditTool?) {
        guard let chosen else { return setTool(nil) }
        if chosen == tool {
            switch chosen {
            case .text: textSize = textSize.next
            case .arrow: arrowStyle = arrowStyle.next
            case .shape: shapeKind = shapeKind.next
            case .redact: break
            }
            updateHint()
        } else {
            setTool(chosen)
        }
    }

    private func setTool(_ newTool: EditTool?) {
        commitText()
        tool = newTool
        imageView.tool = newTool
        tools.selectedSegment = (newTool?.rawValue ?? 0) - 1  // -1 clears the selection
        editHint.isHidden = newTool == nil
        if newTool == .redact { startScanIfNeeded() }
        updateHint()
        updateRedactStatus()
        renderPreview()
    }

    private func updateHint() {
        let variant: String
        switch tool {
        case .text: variant = "Text: \(textSize.rawValue) — press 1 to change size  ·  Click to type"
        case .arrow: variant = "Arrow: \(arrowStyle == .normal ? "straight" : "curved \(arrowStyle.rawValue)") — press 2 to change  ·  Drag to draw"
        case .shape: variant = "Shape: \(shapeKind.rawValue) — press 4 to change  ·  Drag to draw"
        case .redact: variant = "Click text to hide or show it  ·  Drag to draw a box"
        case nil: variant = ""
        }
        hintLabel.stringValue = variant + "  ·  Esc when done"
    }

    /// Number keys 1–4 pick tools; Esc leaves the tool, then closes the window.
    /// Typing in a text annotation never gets here: the field editor handles those keys.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return cancelOperation(nil) }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
           let chosen = EditTool(rawValue: digit) {
            return selectTool(chosen)
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if tool != nil { setTool(nil) } else { close() }
    }

    private func annotation(from: CGPoint, to: CGPoint) -> Annotation? {
        switch tool {
        case .arrow: return .arrow(from: from, to: to, style: arrowStyle)
        case .shape: return .shape(from: from, to: to, kind: shapeKind)
        default: return nil
        }
    }

    private func clicked(at point: CGPoint) {
        switch tool {
        case .redact:
            let before = edits
            guard edits.click(at: point, auto: autoRegions, words: words) else { return }
            history.append((annotations, before))
            changed()
        case .text:
            // A click while typing just finishes that text, like clicking away.
            if activeText != nil { commitText() } else { beginText(at: point) }
        default:
            break
        }
    }

    private func dragged(from: CGPoint, to: CGPoint) {
        switch tool {
        case .redact:
            let before = edits
            guard edits.addBox(CGRect(x: min(from.x, to.x), y: min(from.y, to.y),
                                      width: abs(to.x - from.x), height: abs(to.y - from.y))) else { return }
            history.append((annotations, before))
            changed()
        case .arrow, .shape:
            guard let annotation = annotation(from: from, to: to) else { return }
            history.append((annotations, edits))
            annotations.append(annotation)
            changed()
        default:
            break
        }
    }

    private func changed() {
        updateRedactStatus()
        renderPreview()
    }

    // MARK: - Text annotations

    private func beginText(at point: CGPoint) {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: textSize.points * scale * imageView.viewScale, weight: .semibold)
        field.textColor = Annotator.color
        field.placeholderString = "Type…"
        field.delegate = self
        field.sizeToFit()
        field.frame.size.width = max(160, field.frame.width)
        // The annotation's origin is its top-left; NSTextField pads its text by about 2 pt.
        let viewPoint = imageView.toView(point)
        field.frame.origin = NSPoint(x: viewPoint.x - 2, y: viewPoint.y - field.frame.height)
        imageView.addSubview(field)
        activeText = (field, point)
        updateTypingKeys()
        window?.makeFirstResponder(field)
    }

    /// Return and Esc while typing finish or cancel the text instead of copying/closing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): commitText(); return true
        case #selector(NSResponder.cancelOperation(_:)): cancelText(); return true
        default: return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = activeText?.field else { return }
        let width = field.frame.width
        field.sizeToFit()
        field.frame.size.width = max(160, field.frame.width + 12, width)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    private func commitText() {
        guard let (field, origin) = activeText else { return }
        activeText = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        updateTypingKeys()
        window?.makeFirstResponder(nil)
        guard !text.isEmpty else { return }
        history.append((annotations, edits))
        annotations.append(.text(text, origin: origin, size: textSize))
        changed()
    }

    private func cancelText() {
        guard let (field, _) = activeText else { return }
        activeText = nil
        field.removeFromSuperview()
        updateTypingKeys()
        window?.makeFirstResponder(nil)
    }

    /// While typing, Return must reach the text field rather than the Copy button.
    private func updateTypingKeys() {
        copyButton.keyEquivalent = activeText == nil ? "\r" : ""
    }

    // MARK: - Undo

    @objc func undo(_ sender: Any?) {
        guard activeText == nil else { return cancelText() }
        guard let (previousAnnotations, previousEdits) = history.popLast() else { return NSSound.beep() }
        annotations = previousAnnotations
        edits = previousEdits
        changed()
    }

    // MARK: - Redaction

    /// Auto-redact matches for the current categories (empty when auto-redact is off).
    private var autoRegions: [RedactRegion] {
        guard Preferences.autoRedact(), let lines else { return [] }
        return Redactor.regions(in: lines, categories: Preferences.redactCategories())
    }

    /// Everything that will be covered: auto matches (minus revealed ones) plus manual blocks.
    private var effectiveRegions: [RedactRegion] { edits.effective(auto: autoRegions) }

    /// False while auto-redact is waiting for OCR.
    private var redactionReady: Bool { !Preferences.autoRedact() || lines != nil }

    private func startScanIfNeeded() {
        guard lines == nil, !isScanning, let source, let raw else { return }
        isScanning = true
        scanGeneration += 1
        let generation = scanGeneration
        scanQueue.async { [weak self] in
            let found = (try? Redactor.recognize(source)) ?? []
            DispatchQueue.main.async {
                guard let self, generation == self.scanGeneration, self.raw == raw else { return }
                self.isScanning = false
                self.setLines(found)
            }
        }
    }

    private func setLines(_ found: [TextLine]) {
        lines = found
        words = Redactor.words(in: found)
        updateRedactStatus()
        renderPreview()
    }

    /// Blocks until OCR is done when auto-redact needs it. Used by Copy/Save so they never
    /// output an unredacted image. Throws if OCR fails.
    private func ensureRegions() throws {
        guard !redactionReady, let source else { return }
        scanGeneration += 1  // drop any in-flight async scan
        isScanning = false
        setLines(try Redactor.recognize(source))
    }

    private func updateRedactStatus() {
        let regions = effectiveRegions
        if tool == .redact && lines == nil {
            redactStatus.stringValue = "Reading text…"
        } else if tool == .redact {
            redactStatus.stringValue = "\(regions.count) hidden"
        } else if !Preferences.autoRedact() && edits.isEmpty {
            redactStatus.stringValue = ""
        } else if Preferences.autoRedact() && Preferences.redactCategories().isEmpty && edits.isEmpty {
            redactStatus.stringValue = "No categories"
        } else if !redactionReady {
            redactStatus.stringValue = "Scanning…"
        } else {
            redactStatus.stringValue = regions.isEmpty ? "Nothing hidden" : "\(regions.count) hidden"
        }
        let categories = Preferences.redactCategories()
        let hidden = regions.map { $0.text.isEmpty ? "(box)" : $0.text }
        redactStatus.toolTip = "Auto-redact looks for: " + RedactCategory.allCases.filter(categories.contains).map(\.title).joined(separator: ", ")
            + (hidden.isEmpty ? "" : "\nHidden: " + hidden.joined(separator: ", "))
    }

    // MARK: - Rendering

    /// True when the output differs from the raw capture file.
    private var isProcessed: Bool {
        Preferences.beautify() || !effectiveRegions.isEmpty || !annotations.isEmpty
    }

    /// The image Copy/Save produce for the current settings.
    private func finalImage() throws -> CGImage? {
        commitText()
        try ensureRegions()
        guard let source else { return nil }
        return Pipeline.render(source, redactions: effectiveRegions, redactColor: Preferences.redactColor(),
                               annotations: annotations, style: Preferences.beautify() ? style : nil, scale: scale)
    }

    private func renderPreview() {
        guard let source else { return }
        renderGeneration += 1
        let generation = renderGeneration
        // Until the scan finishes, auto matches aren't shown yet (status says "Scanning…").
        // With a tool active the plain capture is shown, so clicks map straight onto its pixels.
        let editing = tool != nil
        let (redactions, color, annotations, style, scale) = (effectiveRegions, Preferences.redactColor(), annotations,
                                                              Preferences.beautify() && !editing ? self.style : nil, self.scale)
        imageView.capturePixelSize = CGSize(width: source.width, height: source.height)
        imageView.captureScale = scale
        imageView.targets = tool == .redact ? words.map(\.rect) + redactions.map(\.coveredRect) : []
        renderQueue.async { [weak self] in
            guard let output = Pipeline.render(source, redactions: redactions, redactColor: color,
                                               annotations: annotations, style: style, scale: scale) else { return }
            let image = NSImage(cgImage: output, size: NSSize(width: CGFloat(output.width) / scale,
                                                              height: CGFloat(output.height) / scale))
            DispatchQueue.main.async {
                guard let self, generation == self.renderGeneration else { return }
                self.imageView.image = image
            }
        }
    }

    /// Shown instead of silently falling back to the unredacted capture.
    private func showScanFailure(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't scan for sensitive text"
        alert.informativeText = "Nothing was copied or saved. Turn off Redact to use the capture as is.\n\n\(error.localizedDescription)"
        alert.beginSheetModal(for: window)
    }

    // MARK: - Actions

    /// Edit → Copy (⌘C) reaches here through the responder chain when no text field has focus.
    @objc func copy(_ sender: Any?) { copyImage() }

    @objc private func copyImage() {
        guard let raw else { return }
        let image: CGImage
        do {
            guard let rendered = try finalImage() else { return }
            image = rendered
        } catch {
            return showScanFailure(error)
        }
        var copied = raw
        if isProcessed {
            do {
                copied = try Beautifier.writeOutput(image, forRaw: raw)
            } catch {
                NSLog("SnapSmith: could not write processed image: \(error)")
                return
            }
        }
        ScreenCapturer.copyToClipboard(copied)
        onCopied?()
        if Preferences.closeAfterCopy() { close() }
    }

    @objc private func save() {
        guard let raw, let window else { return }
        // Render before the panel opens, so a scan failure stops the save up front.
        let image: CGImage
        do {
            guard let rendered = try finalImage() else { return }
            image = rendered
        } catch {
            return showScanFailure(error)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = raw.lastPathComponent
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try Beautifier.writePNG(image, to: url)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc private func openStyle() { onOpenStyle?() }

    @objc private func closeWindow() { close() }
}

/// NSWindow handles Esc itself (as cancelOperation:) instead of passing it up the responder
/// chain, so forward it to the controller: Esc leaves the active tool first, then closes.
private final class PreviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        if let controller = windowController as? PreviewWindowController {
            controller.cancelOperation(sender)
        } else {
            super.cancelOperation(sender)
        }
    }
}
