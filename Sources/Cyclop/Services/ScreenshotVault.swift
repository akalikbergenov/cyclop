import AppKit

/// Where clipboard screenshots are kept.
///
/// A screenshot taken to the clipboard exists only in memory: paste it once and
/// it is gone. The vault writes it to disk so the shelf can hold on to it.
/// Files stay unless the user clears the folder, or opts into trashing a
/// screenshot file when explicitly removing its card from the Shelf.
enum ScreenshotVault {
    /// `~/Pictures/Cyclop` when it can be created — it is findable, and unlike
    /// Desktop or Documents it is not behind a TCC prompt. Falls back to the
    /// app's own support folder, which always works.
    static let folder: URL = {
        let fm = FileManager.default
        let pictures = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("Cyclop", isDirectory: true)
        if (try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)) != nil {
            return pictures
        }
        return Support.directory("Screenshots")
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = localized("yyyy-MM-dd 'at' HH.mm.ss")
        return formatter
    }()

    static func save(_ png: Data, at date: Date = Date()) -> URL? {
        let base = "\(localized("Screenshot")) \(stamp.string(from: date))"
        var url = folder.appendingPathComponent("\(base).png")
        // Two screenshots inside one second would otherwise collide.
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(attempt)).png")
            attempt += 1
        }
        do {
            try png.write(to: url, options: .atomic)
            if !ScreenshotFiles(legacyFolders: legacyFolders).markScreenshot(url) {
                NSLog("Cyclop: could not mark saved screenshot; legacy vault recognition remains available")
            }
            return url
        } catch {
            NSLog("Cyclop: failed to save image: \(error.localizedDescription)")
            return nil
        }
    }

    /// Both historical locations, computed without creating or reading either.
    private static var legacyFolders: [URL] {
        let fm = FileManager.default
        return [
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Cyclop", isDirectory: true),
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Cyclop/Screenshots", isDirectory: true),
        ]
    }

    static func trashIfScreenshot(_ url: URL) throws {
        try ScreenshotFiles(legacyFolders: legacyFolders).trashIfScreenshot(url)
    }

    static func reveal() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    /// What the folder holds right now — for the menu item that offers to
    /// clear it, so the offer names its price.
    static func usage() -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        let bytes = urls.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return (urls.count, bytes)
    }

    /// To the Trash, not gone. The folder's promise is that nothing in it is
    /// ever deleted behind the user's back; the menu item is the user's own
    /// hand, and the Trash keeps even that reversible.
    static func clear() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }
}
