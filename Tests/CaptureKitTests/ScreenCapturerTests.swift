import AppKit
import XCTest
import Carbon.HIToolbox
@testable import CaptureKit

final class ScreenCapturerTests: XCTestCase {
    func testDefaultArguments() {
        // interactive, no window shadow, no attached windows, explicit output path
        XCTAssertEqual(ScreenCapturer.arguments(for: CaptureOptions(), outputPath: "/tmp/x.png"),
                       ["-i", "-o", "-a", "/tmp/x.png"])
    }

    func testWindowModeAddsW() {
        XCTAssertEqual(ScreenCapturer.arguments(for: CaptureOptions(mode: .window), outputPath: "/o.png"),
                       ["-i", "-o", "-a", "-w", "/o.png"])
    }

    func testOptionalFlags() {
        var options = CaptureOptions()
        options.includeWindowShadow = true
        options.includeAttachedWindows = true
        options.playSound = false
        XCTAssertEqual(ScreenCapturer.arguments(for: options, outputPath: "/o.png"),
                       ["-i", "-x", "/o.png"])
    }

    func testArchiveMovesFileWithTimestampAndAvoidsCollisions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let capturer = ScreenCapturer(archiveDirectory: dir)

        let first = try capturer.archive(try makePNG())
        let second = try capturer.archive(try makePNG())

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("SnapSmith-"))
    }

    func testArchiveRejectsNonImage() throws {
        let bogus = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try Data("not an image".utf8).write(to: bogus)
        defer { try? FileManager.default.removeItem(at: bogus) }
        XCTAssertThrowsError(try ScreenCapturer(archiveDirectory: FileManager.default.temporaryDirectory).archive(bogus))
    }

    private func makePNG() throws -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }
}

final class BeautifierTests: XCTestCase {
    func testCanvasGrowsByPaddingOnEachSide() throws {
        var style = BeautifyStyle()
        style.padding = 50
        let source = try XCTUnwrap(solidImage(width: 200, height: 100))
        let output = try XCTUnwrap(Beautifier.beautify(source, style: style))
        XCTAssertEqual(output.width, 300)
        XCTAssertEqual(output.height, 200)
    }

    func testLengthsArePointsScaledForRetina() throws {
        var style = BeautifyStyle()
        style.padding = 24
        let source = try XCTUnwrap(solidImage(width: 3358, height: 1806))
        // Padding 24 pt at 2x adds 48 px per side: 3358 + 96.
        XCTAssertEqual(try XCTUnwrap(Beautifier.beautify(source, style: style, scale: 2)).width, 3454)
    }

    func testOutputURLMirrorsRawIntoOutputFolder() {
        let raw = URL(fileURLWithPath: "/a/Archives/Raw/x.png")
        XCTAssertEqual(ScreenCapturer.outputURL(forRaw: raw).path, "/a/Archives/Output/x.png")
    }

    func testRecognizesRenderedText() throws {
        let size = NSSize(width: 900, height: 140)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("Hello SnapSmith" as NSString).draw(at: NSPoint(x: 30, y: 30),
            withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(try TextRecognizer.recognizeText(in: cgImage), "Hello SnapSmith")
    }

    private func solidImage(width: Int, height: Int) -> CGImage? {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setFillColor(NSColor.white.cgColor)
        ctx?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx?.makeImage()
    }
}

final class InsetTests: XCTestCase {
    /// White 300×200 with a red 100×50 box; margins top 10, left 30, bottom 140, right 170.
    private func boxImage() -> CGImage {
        let ctx = Bitmap.context(width: 300, height: 200)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 30, y: 140, width: 100, height: 50))  // bottom-left origin
        return ctx.makeImage()!
    }

    private let white = Inset.RGBA(r: 255, g: 255, b: 255)

    func testDetectsBorderAndMargins() throws {
        let bitmap = try XCTUnwrap(Bitmap(boxImage()))
        XCTAssertEqual(Inset.borderColor(of: bitmap, tolerance: 8), white)
        XCTAssertEqual(Inset.contentMargins(of: bitmap, background: white, tolerance: 8),
                       Inset.Margins(top: 10, left: 30, bottom: 140, right: 170))
    }

    func testBalancedInsetCentresContent() throws {
        let output = try XCTUnwrap(Inset.apply(to: boxImage(), inset: 20, balance: true))
        XCTAssertEqual(output.width, 140)
        XCTAssertEqual(output.height, 90)
        XCTAssertEqual(Inset.contentMargins(of: try XCTUnwrap(Bitmap(output)), background: white, tolerance: 8),
                       Inset.Margins(top: 20, left: 20, bottom: 20, right: 20))
    }

    func testUnbalancedInsetKeepsRelativeOffsets() throws {
        let output = try XCTUnwrap(Inset.apply(to: boxImage(), inset: 20, balance: false))
        XCTAssertEqual(Inset.contentMargins(of: try XCTUnwrap(Bitmap(output)), background: white, tolerance: 8),
                       Inset.Margins(top: 20, left: 40, bottom: 150, right: 180))
    }

    func testSkipsImagesWithoutSolidBorder() {
        let ctx = Bitmap.context(width: 100, height: 100)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        XCTAssertNil(Inset.apply(to: ctx.makeImage()!, inset: 20, balance: true))
    }
}

final class StyleStoreTests: XCTestCase {
    func testRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "snapsmith-tests-\(UUID())"))
        var style = BeautifyStyle()
        style.padding = 33
        style.inset = 12
        style.insetBalance = false
        style.gradientStart = try XCTUnwrap(StyleStore.color(hex: "#c04180"))
        StyleStore.save(style, to: defaults)

        let loaded = StyleStore.load(from: defaults)
        XCTAssertEqual(loaded.padding, 33)
        XCTAssertEqual(loaded.inset, 12)
        XCTAssertFalse(loaded.insetBalance)
        XCTAssertEqual(StyleStore.hex(loaded.gradientStart), "#c04180")
    }
}

final class PreferencesTests: XCTestCase {
    private func freshDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "snapsmith-prefs-\(UUID())"))
    }

    func testDefaults() throws {
        let defaults = try freshDefaults()
        XCTAssertTrue(Preferences.closeAfterCopy(defaults: defaults))
        XCTAssertFalse(Preferences.beautify(defaults: defaults))
        XCTAssertFalse(Preferences.autoRedact(defaults: defaults))
        XCTAssertEqual(Preferences.redactCategories(defaults: defaults), [.emails])
        XCTAssertEqual(StyleStore.hex(Preferences.redactColor(defaults: defaults)), "#000000")
    }

    func testSettersPersist() throws {
        let defaults = try freshDefaults()
        Preferences.setCloseAfterCopy(false, defaults: defaults)
        Preferences.setBeautify(true, defaults: defaults)
        Preferences.setAutoRedact(true, defaults: defaults)
        Preferences.setRedactCategory(.creditCards, enabled: true, defaults: defaults)
        Preferences.setRedactCategory(.emails, enabled: false, defaults: defaults)
        Preferences.setRedactColor(try XCTUnwrap(StyleStore.color(hex: "#336699")), defaults: defaults)
        XCTAssertFalse(Preferences.closeAfterCopy(defaults: defaults))
        XCTAssertTrue(Preferences.beautify(defaults: defaults))
        XCTAssertTrue(Preferences.autoRedact(defaults: defaults))
        XCTAssertEqual(Preferences.redactCategories(defaults: defaults), [.creditCards])
        XCTAssertEqual(StyleStore.hex(Preferences.redactColor(defaults: defaults)), "#336699")
    }
}

final class RedactorTests: XCTestCase {
    private func matched(_ text: String, _ categories: Set<RedactCategory>) -> [String] {
        Redactor.matches(in: text, categories: categories).map { String(text[$0.1]) }
    }

    func testPatterns() {
        XCTAssertEqual(matched("Contact jane.doe@example.com today", [.emails]), ["jane.doe@example.com"])
        XCTAssertEqual(matched("Card 4111 1111 1111 1111 exp", [.creditCards]), ["4111 1111 1111 1111"])
        XCTAssertEqual(matched("Card 4111-1111-1111-1111", [.creditCards]), ["4111-1111-1111-1111"])
        XCTAssertEqual(matched("Server 192.168.1.20 up", [.ipAddresses]), ["192.168.1.20"])
        XCTAssertEqual(matched("v6 2001:db8::ff00:42:8329 up", [.ipAddresses]), ["2001:db8::ff00:42:8329"])
        XCTAssertEqual(matched("key demo_abcdefghijklmnopqrstuvwxyz123456 end", [.apiKeys]),
                       ["demo_abcdefghijklmnopqrstuvwxyz123456"])
    }

    func testPlausibilityChecksAvoidFalsePositives() {
        XCTAssertTrue(matched("Order 1234 5678 9012 3456", [.creditCards]).isEmpty)       // fails the Luhn check
        XCTAssertTrue(matched("Version 999.1.1.1", [.ipAddresses]).isEmpty)               // not an IPv4 address
        XCTAssertTrue(matched("synced 10:30 and 10:30:45", [.ipAddresses]).isEmpty)       // times are not IPv6
        XCTAssertTrue(matched("call Foo::bar()", [.ipAddresses]).isEmpty)                 // code is not IPv6
        XCTAssertTrue(matched("internationalizationconfigurationmanager", [.apiKeys]).isEmpty)  // letters only
        XCTAssertTrue(matched("12345678901234567890123456789012", [.apiKeys]).isEmpty)    // digits only
    }

    func testDisabledCategoriesAreIgnored() {
        XCTAssertEqual(matched("jane@example.com 1.2.3.4", [.ipAddresses]), ["1.2.3.4"])
    }

    func testApplyCoversRegionWithColour() throws {
        let ctx = try XCTUnwrap(Bitmap.context(width: 100, height: 100))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let region = RedactRegion(rect: CGRect(x: 20, y: 10, width: 40, height: 20), category: .emails, text: "x")
        let output = try XCTUnwrap(Redactor.apply([region], to: try XCTUnwrap(ctx.makeImage()), color: .black))
        let bitmap = try XCTUnwrap(Bitmap(output))
        XCTAssertEqual(bitmap[40, 20], Inset.RGBA(r: 0, g: 0, b: 0))      // inside (top-left origin)
        XCTAssertEqual(bitmap[40, 80], Inset.RGBA(r: 255, g: 255, b: 255)) // untouched
    }
}

final class RedactionEditsTests: XCTestCase {
    private let email = RedactRegion(rect: CGRect(x: 100, y: 10, width: 200, height: 20), category: .emails, text: "a@b.co")
    private let time = RedactRegion(rect: CGRect(x: 100, y: 60, width: 50, height: 20), category: .ipAddresses, text: "10:30")
    private let word = RedactRegion(rect: CGRect(x: 10, y: 100, width: 60, height: 20), category: nil, text: "Secret")

    func testClickTogglesAutoMatch() {
        var edits = RedactionEdits()
        let auto = [email, time]
        edits.click(at: CGPoint(x: 120, y: 70), auto: auto, words: [])
        XCTAssertEqual(edits.effective(auto: auto).map(\.text), ["a@b.co"])
        edits.click(at: CGPoint(x: 120, y: 70), auto: auto, words: [])
        XCTAssertEqual(edits.effective(auto: auto).map(\.text), ["a@b.co", "10:30"])
    }

    func testClickTogglesPlainWord() {
        var edits = RedactionEdits()
        edits.click(at: CGPoint(x: 20, y: 110), auto: [], words: [word])
        XCTAssertEqual(edits.effective(auto: []).map(\.text), ["Secret"])
        edits.click(at: CGPoint(x: 20, y: 110), auto: [], words: [word])
        XCTAssertTrue(edits.isEmpty)
    }

    func testAutoMatchWinsOverWordBeneathIt() {
        var edits = RedactionEdits()
        let duplicateWord = RedactRegion(rect: email.rect, category: nil, text: "a@b.co")
        edits.click(at: CGPoint(x: 150, y: 20), auto: [email], words: [duplicateWord])
        XCTAssertTrue(edits.added.isEmpty)
        XCTAssertEqual(edits.revealedAuto, [email.rect])
    }

    func testDrawnBoxes() {
        var edits = RedactionEdits()
        XCTAssertTrue(edits.addBox(CGRect(x: 300, y: 300, width: -80, height: -40)))
        XCTAssertEqual(edits.added.last?.rect, CGRect(x: 220, y: 260, width: 80, height: 40))
        XCTAssertFalse(edits.addBox(CGRect(x: 0, y: 0, width: 3, height: 50)))
        XCTAssertEqual(edits.added.last?.coveredRect, CGRect(x: 220, y: 260, width: 80, height: 40))  // not padded
        edits.click(at: CGPoint(x: 250, y: 280), auto: [], words: [])
        XCTAssertTrue(edits.isEmpty)
    }

    func testWordRanges() {
        let text = "Server  192.168.1.20 · ok"
        XCTAssertEqual(Redactor.wordRanges(in: text).map { String(text[$0]) }, ["Server", "192.168.1.20", "·", "ok"])
    }
}

final class LayoutOptionsTests: XCTestCase {
    private func image(_ width: Int, _ height: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(Bitmap.context(width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    func testWatermarkAddsBandUnderScreenshot() throws {
        var style = BeautifyStyle()
        style.padding = 24
        style.watermark = "Screenshot by SnapSmith"
        let output = try XCTUnwrap(Beautifier.beautify(try image(1180, 680), style: style, scale: 2))
        XCTAssertEqual(output.width, 1276)
        XCTAssertEqual(output.height, 776 + 56)  // 28 pt band at 2x
    }

    func testAspectRatiosAreExact() throws {
        for ratio in AspectRatio.allCases {
            var style = BeautifyStyle()
            style.aspectRatio = ratio
            let output = try XCTUnwrap(Beautifier.beautify(try image(1180, 680), style: style, scale: 2))
            XCTAssertEqual(CGFloat(output.width) / CGFloat(output.height), ratio.value, accuracy: 0.01, ratio.rawValue)
        }
    }

    func testMissingBackgroundImageFallsBackToGradient() throws {
        var style = BeautifyStyle()
        style.background = .image(URL(fileURLWithPath: "/nonexistent.png"))
        XCTAssertNotNil(Beautifier.beautify(try image(100, 100), style: style))
    }

    func testNewOptionsRoundTrip() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "snapsmith-layout-\(UUID())"))
        var style = BeautifyStyle()
        style.background = .image(URL(fileURLWithPath: "/tmp/a b.png"))
        style.aspectRatio = .portrait
        style.watermark = "hi"
        StyleStore.save(style, to: defaults)
        let loaded = StyleStore.load(from: defaults)
        XCTAssertEqual(loaded.background, style.background)
        XCTAssertEqual(loaded.aspectRatio, .portrait)
        XCTAssertEqual(loaded.watermark, "hi")
    }
}

final class AnnotationTests: XCTestCase {
    func testVariantsCycleAndWrap() {
        XCTAssertEqual(Annotation.TextSize.normal.next, .big)
        XCTAssertEqual(Annotation.TextSize.big.next, .small)
        XCTAssertEqual(Annotation.ArrowStyle.left.next, .right)
        XCTAssertEqual(Annotation.ShapeKind.line.next, .rectangle)
    }

    func testShapeIsDrawnAtTopLeftOriginCoordinates() throws {
        let ctx = try XCTUnwrap(Bitmap.context(width: 400, height: 300))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let shape = Annotation.shape(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 250, y: 200), kind: .rectangle)
        let output = try XCTUnwrap(Annotator.apply([shape], to: try XCTUnwrap(ctx.makeImage()), scale: 1))
        let bitmap = try XCTUnwrap(Bitmap(output))
        XCTAssertGreaterThan(bitmap[150, 40].r, 200)   // top edge is red
        XCTAssertLessThan(bitmap[150, 40].g, 80)
        XCTAssertEqual(bitmap[150, 120], Inset.RGBA(r: 255, g: 255, b: 255))  // inside stays clear
    }
}

final class ArchiveCleanerTests: XCTestCase {
    func testOnlyOldSnapSmithPNGsExpire() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("archive-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        for folder in ["Raw", "Output", "Raw/sub"] {
            try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let now = Date()
        func make(_ path: String, daysOld: Double) throws {
            let url = root.appendingPathComponent(path)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.creationDate: now.addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
        }
        try make("Raw/SnapSmith-old.png", daysOld: 5)
        try make("Output/SnapSmith-old.png", daysOld: 4)
        try make("Raw/SnapSmith-new.png", daysOld: 1)
        try make("Raw/holiday-photo.png", daysOld: 30)
        try make("Output/SnapSmith-notes.txt", daysOld: 30)
        try make("Raw/sub/SnapSmith-nested.png", daysOld: 30)

        let expired = ArchiveCleaner.expiredFiles(in: root, olderThan: 3, now: now)
        XCTAssertEqual(expired.map(\.lastPathComponent), ["SnapSmith-old.png", "SnapSmith-old.png"])
        XCTAssertTrue(ArchiveCleaner.expiredFiles(in: root, olderThan: 7, now: now).isEmpty)
    }

    func testRetentionPreference() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "snapsmith-retention-\(UUID())"))
        XCTAssertEqual(Preferences.archiveRetentionDays(defaults: defaults), 3)
        Preferences.setArchiveRetentionDays(10, defaults: defaults)
        XCTAssertEqual(Preferences.archiveRetentionDays(defaults: defaults), 10)
        Preferences.setArchiveRetentionDays(nil, defaults: defaults)
        XCTAssertNil(Preferences.archiveRetentionDays(defaults: defaults))
    }
}

final class ShortcutTests: XCTestCase {
    func testDisplayAndValidity() {
        let optionShift4 = Shortcut(keyCode: kVK_ANSI_4, modifiers: optionKey | shiftKey)
        XCTAssertEqual(optionShift4.displayString, "⌥⇧4")
        XCTAssertTrue(optionShift4.isValid)
        XCTAssertFalse(Shortcut(keyCode: kVK_ANSI_A, modifiers: shiftKey).isValid)
        XCTAssertTrue(Shortcut(keyCode: kVK_F6, modifiers: 0).isValid)
        XCTAssertEqual(Shortcut(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey).displayString, "⇧⌘4")
    }

    func testSystemScreenshotShortcuts() {
        XCTAssertTrue(Shortcut(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey).isSystemScreenshotShortcut)
        XCTAssertTrue(Shortcut(keyCode: kVK_ANSI_3, modifiers: cmdKey | shiftKey | controlKey).isSystemScreenshotShortcut)
        XCTAssertFalse(Shortcut(keyCode: kVK_ANSI_4, modifiers: optionKey | shiftKey).isSystemScreenshotShortcut)
    }

    func testShortcutPreferences() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "snapsmith-shortcuts-\(UUID())"))
        XCTAssertEqual(Preferences.shortcut(for: .captureArea, defaults: defaults), ShortcutAction.captureArea.defaultShortcut)
        let custom = Shortcut(keyCode: kVK_ANSI_9, modifiers: controlKey | optionKey)
        Preferences.setShortcut(custom, for: .captureArea, defaults: defaults)
        XCTAssertEqual(Preferences.shortcut(for: .captureArea, defaults: defaults), custom)
        Preferences.setShortcut(nil, for: .captureArea, defaults: defaults)
        XCTAssertNil(Preferences.shortcut(for: .captureArea, defaults: defaults))
        Preferences.resetShortcuts(defaults: defaults)
        XCTAssertEqual(Preferences.shortcut(for: .captureArea, defaults: defaults), ShortcutAction.captureArea.defaultShortcut)
    }

    func testReleasingHotKeyUnregistersIt() throws {
        let shortcut = Shortcut(keyCode: kVK_F19, modifiers: controlKey | optionKey | shiftKey)
        var hotKey = HotKey(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers), handler: {})
        XCTAssertNotNil(hotKey)
        XCTAssertNil(HotKey(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers), handler: {}))  // taken
        hotKey = nil
        XCTAssertNotNil(HotKey(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers), handler: {}))  // free again
    }
}
