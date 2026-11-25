import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ShelfImageReference: Sendable {
    let id: UUID
    let url: URL
}

/// Derived solely from active cards. File decoding runs off the main actor;
/// mutations and the final import decision share the Shelf's main actor.
@MainActor
final class ShelfImageIndex {
    struct Record: Codable, Sendable {
        let fingerprint: ImageFingerprint?
        let size: Int?
        let modified: Date?
    }

    typealias Snapshot = [String: Record]
    var onChange: (() -> Void)?

    private var references: [UUID: URL] = [:]
    private var records: [UUID: Record] = [:]
    private var pendingCache: [UUID: Record] = [:]
    private var matches: [ImageFingerprint: Set<UUID>] = [:]
    private var deferred: Set<UUID> = []
    private var failures: Set<UUID> = []
    private var pending: [UUID: UUID] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var snapshot: Snapshot {
        var result: Snapshot = [:]
        for (id, url) in references {
            if let record = records[id] ?? pendingCache[id], record.fingerprint != nil || record.size != nil {
                result[url.path] = record
            }
        }
        return result
    }

    /// Never stats a restored path. Legacy cards wait until refresh(), which
    /// is called only when the Shelf is shown, preserving its TCC policy.
    func restore(_ items: [ShelfImageReference], cache: Snapshot) {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        pending.removeAll()
        references = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.url) })
        records.removeAll()
        pendingCache.removeAll()
        matches.removeAll()
        deferred.removeAll()
        failures.removeAll()
        for item in items {
            if let record = cache[item.url.path] {
                set(record, for: item.id)
            } else {
                deferred.insert(item.id)
            }
        }
        changed()
    }

    /// Manual additions keep their behavior: they are never content-rejected.
    /// Their fingerprints still participate in later clipboard-only checks.
    func synchronize(_ items: [ShelfImageReference], known: [UUID: ImageFingerprint] = [:]) {
        let active = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.url) })
        for id in Array(references.keys) where active[id] != references[id] {
            tasks.removeValue(forKey: id)?.cancel()
            pending.removeValue(forKey: id)
            pendingCache.removeValue(forKey: id)
            deferred.remove(id)
            failures.remove(id)
            unset(id)
        }
        let previous = references
        references = active
        for item in items {
            if let fingerprint = known[item.id] {
                tasks.removeValue(forKey: item.id)?.cancel()
                pending.removeValue(forKey: item.id)
                pendingCache.removeValue(forKey: item.id)
                deferred.remove(item.id)
                failures.remove(item.id)
                set(Record(fingerprint: fingerprint, size: nil, modified: nil), for: item.id)
            } else if previous[item.id] != item.url {
                read(item.id, at: item.url)
            }
        }
        changed()
    }

    /// Checks signatures first. Unchanged files reuse cached hashes, rather
    /// than decoding all sixty cards on every hover over the Shelf.
    func refresh() {
        for (id, url) in references where pending[id] == nil {
            read(id, at: url)
        }
        changed()
    }

    /// nil means verification failed or the caller was cancelled. It never
    /// means "safe to import". Wait for manual/restored cards before saving.
    func contains(_ fingerprint: ImageFingerprint) async -> Bool? {
        while !Task.isCancelled {
            if matches[fingerprint]?.isEmpty == false { return true }
            if pending.isEmpty && deferred.isEmpty {
                return failures.isEmpty ? false : nil
            }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiters[id] = continuation
                    if Task.isCancelled { resume(id) }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.resume(id) }
            }
        }
        return nil
    }

    /// Synchronous revalidation immediately before persistence. Even a caller
    /// resuming from an async lookup must not use an earlier Shelf state.
    func canImport(_ fingerprint: ImageFingerprint) -> Bool {
        pending.isEmpty && deferred.isEmpty && failures.isEmpty && matches[fingerprint] == nil
    }

    private func set(_ record: Record, for id: UUID) {
        unset(id)
        records[id] = record
        if let fingerprint = record.fingerprint { matches[fingerprint, default: []].insert(id) }
    }

    private func unset(_ id: UUID) {
        if let fingerprint = records.removeValue(forKey: id)?.fingerprint {
            matches[fingerprint]?.remove(id)
            if matches[fingerprint]?.isEmpty == true { matches.removeValue(forKey: fingerprint) }
        }
    }

    private func resume(_ id: UUID) { waiters.removeValue(forKey: id)?.resume() }

    private func changed() {
        let waiting = waiters
        waiters.removeAll()
        waiting.values.forEach { $0.resume() }
        onChange?()
    }

    private func read(_ id: UUID, at url: URL) {
        let cached = records[id] ?? pendingCache[id]
        // Keep the last durable hash while verification is pending, but
        // remove it from matches so import decisions wait for the fresh result.
        pendingCache[id] = cached
        unset(id)
        deferred.remove(id)
        failures.remove(id)
        let token = UUID()
        pending[id] = token
        tasks[id] = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                autoreleasepool { Self.readFile(url, cached: cached) }
            }.value
            guard let self, self.pending[id] == token, self.references[id] == url else { return }
            self.tasks.removeValue(forKey: id)
            self.pending.removeValue(forKey: id)
            self.pendingCache.removeValue(forKey: id)
            switch result {
            case .record(let record): self.set(record, for: id)
            case .missing:
                self.set(Record(fingerprint: nil, size: nil, modified: nil), for: id)
            case .failed:
                self.failures.insert(id)
                NSLog("Cyclop: cannot fingerprint Shelf file %@; clipboard image import deferred until refresh or removal", url.lastPathComponent)
            }
            self.changed()
        }
    }

    private enum ReadResult: Sendable { case record(Record), missing, failed }

    private nonisolated static func readFile(_ url: URL, cached: Record?) -> ReadResult {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            if let cached, let size = values.fileSize, let modified = values.contentModificationDate,
               cached.size == size, cached.modified == modified { return .record(cached) }
            if values.isDirectory == true {
                return .record(Record(fingerprint: nil, size: values.fileSize, modified: values.contentModificationDate))
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let fingerprint = ImageFingerprint(data: data)
            let recognizedImage = CGImageSourceCreateWithData(data as CFData, nil)
                .map { CGImageSourceGetType($0) != nil } ?? false
            if fingerprint == nil && (recognizedImage
                || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true) {
                return .failed
            }
            return .record(Record(fingerprint: fingerprint, size: values.fileSize, modified: values.contentModificationDate))
        } catch let error as NSError {
            return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError ? .missing : .failed
        }
    }
}
