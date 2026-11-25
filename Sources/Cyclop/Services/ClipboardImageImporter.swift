import Foundation

/// Only this automatic path rejects content duplicates. No NSPasteboard
/// writes, ScreenshotVault access, or UI changes happen for a rejected image.
@MainActor
final class ClipboardImageImporter {
    private let index: ShelfImageIndex
    private let save: (Data) -> URL?
    private let insert: (URL, ImageFingerprint) -> Bool
    private let rollback: (URL) -> Void
    private let isEnabled: () -> Bool
    private var inFlight: Set<ImageFingerprint> = []

    init(
        index: ShelfImageIndex,
        save: @escaping (Data) -> URL?,
        insert: @escaping (URL, ImageFingerprint) -> Bool,
        rollback: @escaping (URL) -> Void,
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.index = index
        self.save = save
        self.insert = insert
        self.rollback = rollback
        self.isEnabled = isEnabled
    }

    func importImage(_ data: Data, onInvalidImage: () -> Void = {}) async -> URL? {
        guard isEnabled(), !Task.isCancelled else { return nil }
        let fingerprint = await Task.detached(priority: .utility) {
            autoreleasepool { ImageFingerprint(data: data) }
        }.value
        guard isEnabled(), !Task.isCancelled else { return nil }
        guard let fingerprint else {
            NSLog("Cyclop: cannot fingerprint clipboard image; not importing")
            onInvalidImage()
            return nil
        }
        // Rewrites of the same image must not retain one compressed buffer
        // and waiting task each while legacy Shelf cards await their first view.
        guard inFlight.insert(fingerprint).inserted else { return nil }
        defer { inFlight.remove(fingerprint) }
        guard let duplicate = await index.contains(fingerprint) else {
            NSLog("Cyclop: Shelf image verification unavailable; not importing clipboard image")
            return nil
        }
        guard !duplicate, isEnabled(), !Task.isCancelled else { return nil }
        let png = await Task.detached(priority: .utility) {
            autoreleasepool { ImageFingerprint.pngData(from: data) }
        }.value
        guard isEnabled(), !Task.isCancelled else { return nil }
        guard let png else {
            NSLog("Cyclop: cannot convert clipboard image to PNG; not importing")
            onInvalidImage()
            return nil
        }

        // No suspension from the final check through registration: another
        // import cannot slip between the check and the Shelf's index update.
        while !index.canImport(fingerprint) {
            guard await index.contains(fingerprint) == false, !Task.isCancelled else { return nil }
        }
        guard isEnabled(), !Task.isCancelled, let url = save(png) else { return nil }
        guard insert(url, fingerprint) else {
            rollback(url) // save must return only a newly created, owned file
            return nil
        }
        return url
    }
}
