import AppKit
import CoreGraphics

/// Interactive screen capture: spawn Apple's `/usr/sbin/screencapture` and let it draw the
/// selection UI (documented in `man screencapture`). Flags used: `-i` interactive, `-o` no
/// window shadow, `-a` no attached windows, `-w` window picking only.
/// The image is written to a temp file rather than sent to the clipboard (`-c`), so the
/// user's clipboard isn't clobbered mid-capture; we copy it ourselves when asked.
/// How SnapSmith lays out and names its archive:
/// `Archives/Originals/SnapSmith 2026-10-12 at 09.30.15.png` for the capture as taken, and
/// `Archives/Edited/<same name>` for the version with redaction, markup and styling applied.
public enum ArchiveLayout {
    public static let originalsFolder = "Originals"
    public static let editedFolder = "Edited"
    public static let filePrefix = "SnapSmith "
    public static let dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
}

public enum CaptureMode: Equatable {
    case interactive   // drag a region, or press Space to toggle to window picking
    case window        // window picking only
}

public struct CaptureOptions: Equatable {
    public var mode: CaptureMode = .interactive
    public var includeWindowShadow = false   // -o strips the shadow
    public var includeAttachedWindows = false // -a excludes sheets and other attached windows
    public var playSound = true

    public init(mode: CaptureMode = .interactive) { self.mode = mode }
}

public enum CaptureError: Error, Equatable {
    case permissionDenied
    case toolFailed(status: Int32)
    case unreadableImage
}

public enum CaptureResult: Equatable {
    case captured(URL)   // the archived PNG
    case cancelled       // user hit Esc; screencapture exits 0 without writing a file
}

public struct ScreenCapturer {
    public static let toolPath = "/usr/sbin/screencapture"

    public let archiveDirectory: URL

    public init(archiveDirectory: URL = ScreenCapturer.defaultArchiveDirectory) {
        self.archiveDirectory = archiveDirectory
    }

    public static var defaultArchiveDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnapSmith/Archives/\(ArchiveLayout.originalsFolder)", isDirectory: true)
    }

    /// Where the edited version of a capture goes: `Archives/Edited/<same name>`.
    public static func outputURL(forRaw raw: URL) -> URL {
        raw.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(ArchiveLayout.editedFolder, isDirectory: true)
            .appendingPathComponent(raw.lastPathComponent)
    }

    /// Builds the argument list for `screencapture`. Pure, so it is unit-tested.
    public static func arguments(for options: CaptureOptions, outputPath: String) -> [String] {
        var args = ["-i"]
        if !options.includeWindowShadow { args.append("-o") }
        if !options.includeAttachedWindows { args.append("-a") }
        if options.mode == .window { args.append("-w") }
        if !options.playSound { args.append("-x") }
        args.append(outputPath)
        return args
    }

    /// Screen Recording permission. Without it screencapture still "succeeds" but
    /// returns only the desktop wallpaper, so check up front.
    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static func openScreenRecordingSettings() {
        // Deep link to the Screen Recording pane of System Settings.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Runs the interactive capture off the main thread and calls back on the main queue.
    public func capture(_ options: CaptureOptions = CaptureOptions(),
                        completion: @escaping (Result<CaptureResult, CaptureError>) -> Void) {
        guard Self.hasScreenRecordingPermission() else {
            Self.requestScreenRecordingPermission()
            completion(.failure(.permissionDenied))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.captureSync(options)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Blocks until the user finishes or cancels the selection.
    public func captureSync(_ options: CaptureOptions) -> Result<CaptureResult, CaptureError> {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapsmith-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.toolPath)
        process.arguments = Self.arguments(for: options, outputPath: tempURL.path)
        do {
            try process.run()
        } catch {
            return .failure(.toolFailed(status: -1))
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return .failure(.toolFailed(status: process.terminationStatus))
        }
        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            return .success(.cancelled)
        }
        do {
            return .success(.captured(try archive(tempURL)))
        } catch let error as CaptureError {
            return .failure(error)
        } catch {
            return .failure(.unreadableImage)
        }
    }

    /// Moves the capture into the archive under a timestamped name:
    /// `SnapSmith 2026-10-12 at 09.30.15.png`.
    func archive(_ source: URL) throws -> URL {
        guard NSImage(contentsOf: source) != nil else { throw CaptureError.unreadableImage }
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = ArchiveLayout.dateFormat
        let stamp = formatter.string(from: Date())
        var destination = archiveDirectory.appendingPathComponent("\(ArchiveLayout.filePrefix)\(stamp).png")
        var suffix = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            suffix += 1
            destination = archiveDirectory.appendingPathComponent("\(ArchiveLayout.filePrefix)\(stamp) \(suffix).png")
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// Puts the image on the pasteboard as both image data and a file URL.
    public static func copyToClipboard(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image, url as NSURL])
    }
}
