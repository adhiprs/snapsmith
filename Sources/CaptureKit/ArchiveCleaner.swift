import Foundation

/// Removes old captures from SnapSmith's own archive (Archives/Raw and Archives/Output).
/// Only files SnapSmith itself named (`SnapSmith-….png`) are considered, so pictures the
/// user saved elsewhere, or anything else that ends up in the folder, are never touched.
/// Files go to the Trash rather than being deleted outright, so a capture can be recovered.
public enum ArchiveCleaner {
    /// Captures older than `days` (by creation date) in `archiveRoot`'s Raw and Output folders.
    public static func expiredFiles(in archiveRoot: URL, olderThan days: Int, now: Date = Date()) -> [URL] {
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let keys: [URLResourceKey] = [.creationDateKey, .isRegularFileKey]
        return ["Raw", "Output"].flatMap { folder -> [URL] in
            let directory = archiveRoot.appendingPathComponent(folder, isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            return files.filter { file in
                guard file.lastPathComponent.hasPrefix("SnapSmith-"), file.pathExtension.lowercased() == "png",
                      let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true, let created = values.creationDate
                else { return false }
                return created < cutoff
            }
        }
    }

    /// Moves expired captures to the Trash. Returns the files that were removed.
    @discardableResult
    public static func clean(_ archiveRoot: URL, olderThan days: Int, now: Date = Date()) -> [URL] {
        expiredFiles(in: archiveRoot, olderThan: days, now: now).filter { file in
            (try? FileManager.default.trashItem(at: file, resultingItemURL: nil)) != nil
        }
    }
}
