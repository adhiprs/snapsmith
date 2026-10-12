import AppKit
import CaptureKit
import UniformTypeIdentifiers

/// Shown after every image capture: preview the result, mark it up, tweak the common
/// options, then Copy (⌘C) or Save. Closes after copying when "Close after copy" is on
/// (the default).
///
/// Tools are picked from the toolbar or the keyboard (T text, A arrow, R redact, B box, or
/// 1–4, depending on the user's `ToolKeyScheme`); Shift + the key cycles the tool's variant,
/// and the options strip under the toolbar holds the variant picker, text size and colour.
/// Text is read once per capture (OCR is the slow part) for auto-redact matches and the
/// clickable words in redact mode. Rendering order: redact → markup → beautify. With
/// auto-redact on, Copy/Save wait for the scan, so an unredacted image never reaches the clipboard.
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
    // Options strip under the toolbar
    private let hintLabel = NSTextField(labelWithString: "")
    private let variantPopup = NSPopUpButton()
    private let sizeSegments = NSSegmentedControl(labels: TextSizePreset.allCases.map(\.title), trackingMode: .selectOne,
                                                  target: nil, action: nil)
    private let sizeSlider = NSSlider(value: 24, minValue: 10, maxValue: 96, target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let controlsStack = NSStackView()

    // Redaction state (per capture)
    private var lines: [TextLine]?
    private var words: [RedactRegion] = []
    private var edits = RedactionEdits()
    private let scanQueue = DispatchQueue(label: "snapsmith.redact-scan")
    private var scanGeneration = 0
    private var isScanning = false

    // Markup state (per capture); each tool's variant persists across captures
    private var annotations: [Annotation] = []
    private var tool: EditTool?
    private var textSize: CGFloat = TextSizePreset.medium.points
    private var textLook: Annotation.TextLook = .label
    private var arrowStyle: Annotation.ArrowStyle = .pointer
    private var shapeKind: Annotation.ShapeKind = .box
    private var activeText: (field: NSTextField, origin: CGPoint)?

    /// Undo stack of earlier (markup, redaction edits) states.
    private var history: [([Annotation], RedactionEdits)] = []

    private let renderQueue = DispatchQueue(label: "snapsmith.capture-preview")
    private var renderGeneration = 0
    private var observers: [NSObjectProtocol] = []

    private var scheme: ToolKeyScheme { Preferences.toolKeyScheme() }

    init() {
        let window = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
        window.title = "SnapSmith"
        window.isReleasedWhenClosed = false
        window.level = .floating  // stay above the app that was just captured
        window.minSize = NSSize(width: 900, height: 420)
        super.init(window: window)
        window.delegate = self
        buildToolbar()
        buildUI()

        // Keep in sync with the Style window, the shortcuts window and the menu.
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
            tools.setImage(NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title), forSegment: tool.rawValue - 1)
        }
        tools.target = self
        tools.action = #selector(toolClicked)
        refreshToolLabels()

        let toolbar = NSToolbar(identifier: "SnapSmithPreview")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    /// Segment captions show the key for the current scheme ("Text T" or "Text 1").
    private func refreshToolLabels() {
        for tool in EditTool.allCases {
            let index = tool.rawValue - 1
            let key = tool.key(scheme)
            tools.setLabel("\(tool.title) \(key)", forSegment: index)
            tools.setToolTip("\(tool.title) (\(key)). Shift+\(key) changes its style.", forSegment: index)
        }
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
        // Weakest possible: the image view absorbs whatever space the bars leave.
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
        // Esc is handled in cancelOperation so it can mean "leave the tool" first.
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

        // Options strip: a hint on the left, the active tool's options on the right.
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        variantPopup.controlSize = .small
        variantPopup.target = self
        variantPopup.action = #selector(variantChanged)
        sizeSegments.controlSize = .small
        sizeSegments.target = self
        sizeSegments.action = #selector(sizePresetChanged)
        sizeSlider.controlSize = .small
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeSliderChanged)
        sizeSlider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.isContinuous = true
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 22).isActive = true
        colorWell.toolTip = "Markup colour"
        controlsStack.setViews([variantPopup, sizeSegments, sizeSlider, colorWell], in: .leading)
        controlsStack.spacing = 8

        let strip = NSStackView(views: [hintLabel, controlsStack])
        strip.spacing = 12
        strip.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 4, right: 16)
        strip.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true

        let background = NSVisualEffectView()
        background.material = .underWindowBackground

        for view in [background, strip, imageView, bar] {
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
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.topAnchor.constraint(equalTo: top, constant: 2),
            imageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            imageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: strip.bottomAnchor, constant: 2),
            imageView.bottomAnchor.constraint(equalTo: bar.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        updateOptionsStrip()
    }

    /// Fits the capture's aspect ratio inside a comfortable on-screen size.
    private func sizeWindowToFit(_ image: CGImage) {
        guard let window, let screen = NSScreen.main?.visibleFrame else { return }
        let chrome = NSSize(width: 32, height: 60 + 36 + 56)  // title bar + toolbar, options strip, bottom bar
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
        refreshToolLabels()
        updateOptionsStrip()
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
        setTool(EditTool(rawValue: tools.selectedSegment + 1))
    }

    private func setTool(_ newTool: EditTool?) {
        commitText()
        tool = newTool
        imageView.tool = newTool
        tools.selectedSegment = (newTool?.rawValue ?? 0) - 1  // -1 clears the selection
        if newTool == .redact { startScanIfNeeded() }
        updateOptionsStrip()
        updateRedactStatus()
        renderPreview()
    }

    private var markupColor: NSColor { Preferences.markupColor() }

    /// Shows the active tool's options (variant picker, text size, colour) and a one-line hint.
    private func updateOptionsStrip() {
        let keys = EditTool.allCases.map { $0.key(scheme) }.joined(separator: " ")
        guard let tool else {
            controlsStack.isHidden = true
            hintLabel.stringValue = "Mark up with the toolbar or the keys \(keys): text, arrow, redact, box."
            return
        }
        controlsStack.isHidden = false
        let key = tool.key(scheme)
        variantPopup.removeAllItems()
        switch tool {
        case .text:
            variantPopup.addItems(withTitles: Annotation.TextLook.allCases.map(\.title))
            variantPopup.selectItem(at: Annotation.TextLook.allCases.firstIndex(of: textLook) ?? 0)
            hintLabel.stringValue = "Click to place text, type, press Return. Shift+\(key) changes the size. Esc when done."
        case .arrow:
            variantPopup.addItems(withTitles: Annotation.ArrowStyle.allCases.map(\.title))
            variantPopup.selectItem(at: Annotation.ArrowStyle.allCases.firstIndex(of: arrowStyle) ?? 0)
            hintLabel.stringValue = "Drag from the tail to the tip. Shift+\(key) changes the style. Esc when done."
        case .shape:
            variantPopup.addItems(withTitles: Annotation.ShapeKind.allCases.map(\.title))
            variantPopup.selectItem(at: Annotation.ShapeKind.allCases.firstIndex(of: shapeKind) ?? 0)
            hintLabel.stringValue = "Drag to draw. Shift+\(key) changes the shape. Esc when done."
        case .redact:
            variantPopup.addItems(withTitles: RedactStyle.allCases.map(\.title))
            variantPopup.selectItem(at: RedactStyle.allCases.firstIndex(of: Preferences.redactStyle()) ?? 0)
            hintLabel.stringValue = "Click text to hide or show it, or drag a box. Shift+\(key) changes how it's hidden. Esc when done."
        }
        sizeSegments.isHidden = tool != .text
        sizeSlider.isHidden = tool != .text
        colorWell.isHidden = tool == .redact
        sizeSlider.doubleValue = Double(textSize)
        sizeSegments.selectedSegment = TextSizePreset.allCases.firstIndex { $0.points == textSize } ?? -1
        colorWell.color = markupColor
    }

    @objc private func variantChanged() {
        let index = variantPopup.indexOfSelectedItem
        switch tool {
        case .text: textLook = Annotation.TextLook.allCases[index]
        case .arrow: arrowStyle = Annotation.ArrowStyle.allCases[index]
        case .shape: shapeKind = Annotation.ShapeKind.allCases[index]
        case .redact: Preferences.setRedactStyle(RedactStyle.allCases[index])  // posts a change that re-renders
        case nil: break
        }
        refocusCanvas()
    }

    @objc private func sizePresetChanged() {
        guard sizeSegments.selectedSegment >= 0 else { return }
        textSize = TextSizePreset.allCases[sizeSegments.selectedSegment].points
        sizeSlider.doubleValue = Double(textSize)
        refocusCanvas()
    }

    @objc private func sizeSliderChanged() {
        textSize = CGFloat(sizeSlider.doubleValue.rounded())
        sizeSegments.selectedSegment = TextSizePreset.allCases.firstIndex { $0.points == textSize } ?? -1
    }

    @objc private func colorChanged() {
        Preferences.setMarkupColor(colorWell.color)
    }

    /// Hands keyboard focus back to the window so tool keys keep working after using a control.
    private func refocusCanvas() {
        window?.makeFirstResponder(nil)
    }

    /// Shift + a tool's key cycles its variant (text: size). With the number keys, pressing the
    /// same key again does too.
    private func cycleVariant(of tool: EditTool) {
        switch tool {
        case .text:
            let presets = TextSizePreset.allCases
            let current = presets.firstIndex { $0.points == textSize } ?? -1
            textSize = presets[(current + 1) % presets.count].points
        case .arrow: arrowStyle = arrowStyle.next
        case .shape: shapeKind = shapeKind.next
        case .redact: Preferences.setRedactStyle(Preferences.redactStyle().next)
        }
        updateOptionsStrip()
    }

    /// Tool keys pick tools; Esc leaves the tool, then closes the window.
    /// Typing in a text annotation never gets here: the field editor handles those keys.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { return cancelOperation(nil) }
        if let (chosen, shift) = EditTool.from(event: event, scheme: scheme) {
            if shift || (scheme == .numbers && chosen == tool) {
                if chosen == tool { cycleVariant(of: chosen) } else { setTool(chosen) }
            } else {
                setTool(chosen)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if tool != nil { setTool(nil) } else { close() }
    }

    private func annotation(from: CGPoint, to: CGPoint) -> Annotation? {
        switch tool {
        case .arrow: return .arrow(from: from, to: to, style: arrowStyle, color: markupColor)
        case .shape: return .shape(from: from, to: to, kind: shapeKind, color: markupColor)
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
        let color = markupColor
        let field = NSTextField(string: "")
        field.isBordered = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: textSize * scale * imageView.viewScale, weight: .semibold)
        field.placeholderString = "Type…"
        if textLook == .label {
            // Preview the label while typing: coloured background, readable text.
            field.drawsBackground = true
            field.backgroundColor = color
            field.textColor = Annotator.readableTextColor(on: color)
            field.wantsLayer = true
            field.layer?.cornerRadius = 6
        } else {
            field.drawsBackground = false
            field.textColor = color
        }
        field.delegate = self
        field.sizeToFit()
        field.frame.size.width = max(160, field.frame.width)
        // The annotation's origin is its top-left (the label box's, for labels), and a label pads its
        // text; place the field so its text lands where the finished text will be.
        // NSTextField itself pads its text by about 2 pt.
        let viewPoint = imageView.toView(point)
        let labelPad = textLook == .label ? CGSize(width: textSize * 0.55, height: textSize * 0.3) : .zero
        let toView = scale * imageView.viewScale
        field.frame.origin = NSPoint(x: viewPoint.x + labelPad.width * toView - 2,
                                     y: viewPoint.y - labelPad.height * toView - field.frame.height)
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
        annotations.append(.text(text, origin: origin, size: textSize, look: textLook, color: markupColor))
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
                               redactStyle: Preferences.redactStyle(), annotations: annotations,
                               style: Preferences.beautify() ? style : nil, scale: scale)
    }

    private func renderPreview() {
        guard let source else { return }
        renderGeneration += 1
        let generation = renderGeneration
        // Until the scan finishes, auto matches aren't shown yet (status says "Scanning…").
        // With a tool active the plain capture is shown, so clicks map straight onto its pixels.
        let editing = tool != nil
        let (redactions, color, redactStyle, annotations, style, scale) = (
            effectiveRegions, Preferences.redactColor(), Preferences.redactStyle(), annotations,
            Preferences.beautify() && !editing ? self.style : nil, self.scale)
        imageView.capturePixelSize = CGSize(width: source.width, height: source.height)
        imageView.captureScale = scale
        imageView.targets = tool == .redact ? words.map(\.rect) + redactions.map(\.coveredRect) : []
        renderQueue.async { [weak self] in
            guard let output = Pipeline.render(source, redactions: redactions, redactColor: color, redactStyle: redactStyle,
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
