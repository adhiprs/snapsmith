import AppKit
import CaptureKit
import UniformTypeIdentifiers

/// Style editor with a live preview of the most recent capture: padding, inset, corner
/// radius, shadow, background, aspect ratio, watermark, auto-redact and archive retention.
final class StyleWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private var style = StyleStore.load()
    private let archiveDirectory: URL

    private let previewView = NSImageView()
    private let padding = NSSlider(value: 0, minValue: 0, maxValue: 128, target: nil, action: nil)
    private let corner = NSSlider(value: 0, minValue: 0, maxValue: 40, target: nil, action: nil)
    private let shadow = NSSlider(value: 0, minValue: 0, maxValue: 60, target: nil, action: nil)
    private let angle = NSSlider(value: 0, minValue: 0, maxValue: 360, target: nil, action: nil)
    private let inset = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let insetEnabled = NSButton(checkboxWithTitle: "Inset", target: nil, action: nil)
    private let balance = NSButton(checkboxWithTitle: "Balance", target: nil, action: nil)
    private let closeAfterCopy = NSButton(checkboxWithTitle: "Close preview after copy", target: nil, action: nil)
    private let autoRedact = NSButton(checkboxWithTitle: "Auto-redact", target: nil, action: nil)
    private let redactCategories: [RedactCategory: NSButton] = Dictionary(uniqueKeysWithValues: RedactCategory.allCases.map {
        ($0, NSButton(checkboxWithTitle: $0.title, target: nil, action: nil))
    })
    private let redactColor = NSColorWell()
    private let retentionEnabled = NSButton(checkboxWithTitle: "Delete captures after", target: nil, action: nil)
    private let retentionField = NSTextField(string: "")
    private let retentionStepper = NSStepper()
    private var observers: [NSObjectProtocol] = []
    private let backgroundPopup = NSPopUpButton()
    private let ratioPopup = NSPopUpButton()
    private let watermarkEnabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let watermarkField = NSTextField(string: "")
    private let watermarkPositionPopup = NSPopUpButton()
    private let redactStylePopup = NSPopUpButton()
    private let startColor = NSColorWell()
    private let endColor = NSColorWell()
    private var valueLabels: [NSSlider: NSTextField] = [:]

    private var sourceImage: CGImage?
    /// Redaction regions for `sourceImage`, valid for the categories they were found with.
    private var regions: [RedactRegion] = []
    private var regionsCategories: Set<RedactCategory>?
    private var scanGeneration = 0
    private var sourceScale: CGFloat = 1
    private let renderQueue = DispatchQueue(label: "snapsmith.preview")
    private var renderGeneration = 0

    init(archiveDirectory: URL) {
        self.archiveDirectory = archiveDirectory
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "SnapSmith Style"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 760)
        super.init(window: window)
        window.delegate = self
        buildUI()
        // Pick up edits made in the preview window.
        for name in [StyleStore.didChange, Preferences.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.isApplyingEdit else { return }
                self.style = StyleStore.load()
                self.syncControls()
                self.renderPreview()
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// True while this window is saving its own edit, so the change notification is ignored.
    private var isApplyingEdit = false

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Reloads the style and the newest capture each time the window is shown.
    func present() {
        style = StyleStore.load()
        loadPreviewSource()
        syncControls()
        renderPreview()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }

        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        previewView.layer?.cornerRadius = 8
        // Otherwise the image's pixel size becomes the view's minimum and the window balloons.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            previewView.setContentCompressionResistancePriority(.defaultLow, for: orientation)
            previewView.setContentHuggingPriority(.defaultLow, for: orientation)
        }

        for slider in [padding, corner, shadow, angle, inset] {
            slider.target = self
            slider.action = #selector(controlChanged)
            slider.isContinuous = true
        }
        for control in [insetEnabled, balance, closeAfterCopy, autoRedact] + Array(redactCategories.values) {
            control.target = self
            control.action = #selector(controlChanged)
        }
        for well in [startColor, endColor, redactColor] {
            well.target = self
            well.action = #selector(controlChanged)
        }

        let colors = NSStackView(views: [startColor, endColor])
        colors.spacing = 8
        let insetRow = NSStackView(views: [insetEnabled, balance])
        insetRow.spacing = 16

        let resetButton = NSButton(title: "Reset", target: self, action: #selector(reset))
        let buttons = NSStackView(views: [resetButton])

        backgroundPopup.addItems(withTitles: ["Gradient", "Desktop wallpaper", "Image…"])
        backgroundPopup.target = self
        backgroundPopup.action = #selector(backgroundChanged)
        ratioPopup.addItems(withTitles: ["Free"] + AspectRatio.allCases.map(\.rawValue))
        ratioPopup.target = self
        ratioPopup.action = #selector(controlChanged)
        watermarkEnabled.target = self
        watermarkEnabled.action = #selector(controlChanged)
        watermarkField.placeholderString = "Screenshot by …"
        watermarkField.delegate = self  // saves as you type
        watermarkField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let watermarkRow = NSStackView(views: [watermarkEnabled, watermarkField])
        watermarkPositionPopup.addItems(withTitles: WatermarkPosition.allCases.map(\.title))
        watermarkPositionPopup.target = self
        watermarkPositionPopup.action = #selector(controlChanged)
        redactStylePopup.addItems(withTitles: RedactStyle.allCases.map(\.title))
        redactStylePopup.target = self
        redactStylePopup.action = #selector(controlChanged)

        // Built row by row: one big heterogeneous literal is too slow for the type checker.
        var gridRows: [[NSView]] = []
        gridRows.append([label("Padding"), row(padding)])
        gridRows.append([label("Rounded"), row(corner)])
        gridRows.append([label("Shadow"), row(shadow)])
        gridRows.append([label("Background"), backgroundPopup])
        gridRows.append([label("Colours"), colors])
        gridRows.append([label("Angle"), row(angle)])
        gridRows.append([label("Ratio"), ratioPopup])
        gridRows.append([label("Watermark"), watermarkRow])
        gridRows.append([label("Position"), watermarkPositionPopup])
        gridRows.append([NSGridCell.emptyContentView, insetRow])
        gridRows.append([label("Inset"), row(inset)])
        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing

        // Auto-redact: master switch, categories in two columns, how they're hidden, then the block colour.
        let categoryButtons: [NSView] = RedactCategory.allCases.compactMap { redactCategories[$0] }
        var categoryRows: [[NSView]] = []
        for start in stride(from: 0, to: categoryButtons.count, by: 2) {
            let second: NSView = start + 1 < categoryButtons.count ? categoryButtons[start + 1] : NSGridCell.emptyContentView
            categoryRows.append([categoryButtons[start], second])
        }
        let categoryGrid = NSGridView(views: categoryRows)
        categoryGrid.columnSpacing = 16
        categoryGrid.rowSpacing = 6
        let styleRow = NSStackView(views: [label("Hide with"), redactStylePopup])
        let colorRow = NSStackView(views: [label("Block colour"), redactColor])
        let redactSection = NSStackView(views: [autoRedact, categoryGrid, styleRow, colorRow])
        redactSection.orientation = .vertical
        redactSection.alignment = .leading
        redactSection.spacing = 8
        redactSection.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        categoryGrid.leadingAnchor.constraint(equalTo: redactSection.leadingAnchor, constant: 20).isActive = true
        styleRow.leadingAnchor.constraint(equalTo: redactSection.leadingAnchor, constant: 20).isActive = true
        colorRow.leadingAnchor.constraint(equalTo: redactSection.leadingAnchor, constant: 20).isActive = true

        // Archive retention: old captures go to the Trash.
        retentionEnabled.target = self
        retentionEnabled.action = #selector(retentionChanged)
        retentionField.formatter = {
            let formatter = NumberFormatter()
            formatter.minimum = 1
            formatter.maximum = 365
            formatter.allowsFloats = false
            return formatter
        }()
        retentionField.alignment = .right
        retentionField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        retentionField.target = self
        retentionField.action = #selector(retentionChanged)
        retentionStepper.minValue = 1
        retentionStepper.maxValue = 365
        retentionStepper.valueWraps = false
        retentionStepper.target = self
        retentionStepper.action = #selector(retentionStepped)
        let retentionRow = NSStackView(views: [retentionEnabled, retentionField, retentionStepper, label("days")])
        retentionRow.spacing = 6
        let retentionNote = NSTextField(wrappingLabelWithString: "Old captures in SnapSmith's archive are moved to the Trash. Files you saved elsewhere are never touched.")
        retentionNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        retentionNote.textColor = .secondaryLabelColor
        retentionNote.preferredMaxLayoutWidth = 290
        let retentionSection = NSStackView(views: [retentionRow, retentionNote])
        retentionSection.orientation = .vertical
        retentionSection.alignment = .leading
        retentionSection.spacing = 4

        let controls = NSStackView(views: [grid, closeAfterCopy, redactSection, retentionSection, buttons])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 20

        for view in [previewView, controls] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            previewView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            previewView.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            previewView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            previewView.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -20),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            controls.widthAnchor.constraint(equalToConstant: 290),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func row(_ slider: NSSlider) -> NSView {
        slider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.widthAnchor.constraint(equalToConstant: 36).isActive = true
        valueLabels[slider] = value
        return NSStackView(views: [slider, value])
    }

    // MARK: - Model ↔ controls

    private func syncControls() {
        padding.doubleValue = Double(style.padding)
        corner.doubleValue = Double(style.cornerRadius)
        shadow.doubleValue = Double(style.shadowRadius)
        angle.doubleValue = Double(style.gradientAngle)
        inset.doubleValue = Double(style.inset ?? 20)
        insetEnabled.state = style.inset == nil ? .off : .on
        balance.state = style.insetBalance ? .on : .off
        startColor.color = style.gradientStart
        endColor.color = style.gradientEnd
        switch style.background {
        case .gradient: backgroundPopup.selectItem(at: 0)
        case .wallpaper: backgroundPopup.selectItem(at: 1)
        case .image(let url):
            backgroundPopup.selectItem(at: 2)
            backgroundPopup.item(at: 2)?.title = url.lastPathComponent
        }
        if case .image = style.background {} else { backgroundPopup.item(at: 2)?.title = "Image…" }
        ratioPopup.selectItem(withTitle: style.aspectRatio?.rawValue ?? "Free")
        watermarkEnabled.state = style.watermark == nil ? .off : .on
        if let text = style.watermark { watermarkField.stringValue = text }
        watermarkPositionPopup.selectItem(withTitle: style.watermarkPosition.title)
        redactStylePopup.selectItem(withTitle: Preferences.redactStyle().title)
        closeAfterCopy.state = Preferences.closeAfterCopy() ? .on : .off
        autoRedact.state = Preferences.autoRedact() ? .on : .off
        let enabled = Preferences.redactCategories()
        for (category, button) in redactCategories { button.state = enabled.contains(category) ? .on : .off }
        redactColor.color = Preferences.redactColor()
        let days = Preferences.archiveRetentionDays()
        retentionEnabled.state = days == nil ? .off : .on
        let shownDays = days ?? Preferences.defaultRetentionDays
        retentionField.integerValue = shownDays
        retentionStepper.integerValue = shownDays
        updateEnabledStates()
        updateValueLabels()
    }

    @objc private func controlChanged() {
        style.padding = CGFloat(padding.doubleValue.rounded())
        style.cornerRadius = CGFloat(corner.doubleValue.rounded())
        style.shadowRadius = CGFloat(shadow.doubleValue.rounded())
        style.gradientAngle = CGFloat(angle.doubleValue.rounded())
        style.inset = insetEnabled.state == .on ? Int(inset.doubleValue.rounded()) : nil
        style.insetBalance = balance.state == .on
        style.gradientStart = startColor.color
        style.gradientEnd = endColor.color
        style.aspectRatio = AspectRatio(rawValue: ratioPopup.titleOfSelectedItem ?? "")
        style.watermark = watermarkEnabled.state == .on ? watermarkText : nil
        style.watermarkPosition = WatermarkPosition.allCases.first { $0.title == watermarkPositionPopup.titleOfSelectedItem } ?? .bottomLeft
        isApplyingEdit = true
        StyleStore.save(style)
        Preferences.setCloseAfterCopy(closeAfterCopy.state == .on)
        Preferences.setAutoRedact(autoRedact.state == .on)
        for (category, button) in redactCategories {
            Preferences.setRedactCategory(category, enabled: button.state == .on)
        }
        Preferences.setRedactColor(redactColor.color)
        Preferences.setRedactStyle(RedactStyle.allCases.first { $0.title == redactStylePopup.titleOfSelectedItem } ?? .block)
        isApplyingEdit = false
        updateEnabledStates()
        updateValueLabels()
        renderPreview()
    }

    @objc private func retentionStepped() {
        retentionField.integerValue = retentionStepper.integerValue
        retentionChanged()
    }

    @objc private func retentionChanged() {
        let days = min(max(retentionField.integerValue, 1), 365)
        retentionStepper.integerValue = days
        isApplyingEdit = true
        Preferences.setArchiveRetentionDays(retentionEnabled.state == .on ? days : nil)
        isApplyingEdit = false
        updateEnabledStates()
    }

    /// The field's text, or a sensible default so turning the watermark on shows something.
    private var watermarkText: String {
        let text = watermarkField.stringValue.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Screenshot by SnapSmith" : text
    }

    func controlTextDidChange(_ obj: Notification) { controlChanged() }

    @objc private func backgroundChanged() {
        switch backgroundPopup.indexOfSelectedItem {
        case 1:
            style.background = .wallpaper
        case 2:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.message = "Choose a background picture"
            guard panel.runModal() == .OK, let url = panel.url else {
                syncControls()  // cancelled: put the popup back
                return
            }
            style.background = .image(url)
        default:
            style.background = .gradient
        }
        isApplyingEdit = true
        StyleStore.save(style)
        isApplyingEdit = false
        syncControls()
        renderPreview()
    }

    private func updateEnabledStates() {
        inset.isEnabled = insetEnabled.state == .on
        balance.isEnabled = insetEnabled.state == .on
        let gradient = backgroundPopup.indexOfSelectedItem == 0
        [startColor, endColor].forEach { $0.isEnabled = gradient }
        angle.isEnabled = gradient
        watermarkField.isEnabled = watermarkEnabled.state == .on
        watermarkPositionPopup.isEnabled = watermarkEnabled.state == .on
        let redacting = autoRedact.state == .on
        redactCategories.values.forEach { $0.isEnabled = redacting }
        redactStylePopup.isEnabled = redacting
        redactColor.isEnabled = redacting
        retentionField.isEnabled = retentionEnabled.state == .on
        retentionStepper.isEnabled = retentionEnabled.state == .on
    }

    private func updateValueLabels() {
        for (slider, label) in valueLabels {
            label.stringValue = slider.isEnabled ? "\(Int(slider.doubleValue.rounded()))" : "–"
        }
        valueLabels[angle]?.stringValue += "°"
    }

    @objc private func reset() {
        style = BeautifyStyle()
        StyleStore.save(style)
        syncControls()
        renderPreview()
    }

    // MARK: - Preview

    private func loadPreviewSource() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: archiveDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files.filter { $0.pathExtension == "png" }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        regions = []
        regionsCategories = nil
        if let newest, let image = Beautifier.loadImage(newest) {
            sourceImage = image
            sourceScale = Beautifier.scale(of: newest)
        } else {
            sourceImage = Self.placeholderImage()
            sourceScale = 2
        }
    }

    /// Renders off the main thread; stale renders are dropped while a slider is dragged.
    /// Shows redaction too (once its scan is done), so the preview matches real output.
    private func renderPreview() {
        guard let source = sourceImage else { return }
        refreshRedaction()
        renderGeneration += 1
        let generation = renderGeneration
        let style = self.style
        let scale = sourceScale
        let redactions = Preferences.autoRedact() && regionsCategories == Preferences.redactCategories() ? regions : []
        let color = Preferences.redactColor()
        let redactStyle = Preferences.redactStyle()
        renderQueue.async { [weak self] in
            guard let output = Pipeline.render(source, redactions: redactions, redactColor: color, redactStyle: redactStyle,
                                               style: style, scale: scale) else { return }
            let image = NSImage(cgImage: output, size: NSSize(width: output.width, height: output.height))
            DispatchQueue.main.async {
                guard let self, generation == self.renderGeneration else { return }
                self.previewView.image = image
            }
        }
    }

    /// Starts a background scan when redaction is on and the cached regions are stale.
    private func refreshRedaction() {
        let categories = Preferences.redactCategories()
        guard Preferences.autoRedact(), regionsCategories != categories, let source = sourceImage else { return }
        scanGeneration += 1
        let generation = scanGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = (try? Redactor.findRegions(in: source, categories: categories)) ?? []
            DispatchQueue.main.async {
                guard let self, generation == self.scanGeneration else { return }
                self.regions = found
                self.regionsCategories = categories
                self.renderPreview()
            }
        }
    }

    /// A fake window shown before the first capture exists.
    private static func placeholderImage() -> CGImage? {
        let size = NSSize(width: 800, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: size.height - 56, width: size.width, height: 56).fill()
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 24 + i * 32, y: Int(size.height) - 38, width: 20, height: 20)).fill()
        }
        ("Take a capture to preview it here" as NSString).draw(
            at: NSPoint(x: 40, y: 220),
            withAttributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold), .foregroundColor: NSColor.darkGray])
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
