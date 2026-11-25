import Foundation
import Testing
@testable import Cyclop

@MainActor
struct ClipboardImageImporterTests {
    private enum Timeout: Error { case duplicateDidNotFinish }

    @Test func identicalDeferredImportsAreCoalescedAndCancellationReleasesReservation() async throws {
        let harness = try Harness()
        defer { harness.folder.remove() }
        harness.index.restore([.init(id: UUID(), url: URL(fileURLWithPath: "/legacy.png"))], cache: [:])
        let image = try ImageFixtures.image()
        try await withThrowingTaskGroup(of: URL?.self) { group in
            defer { group.cancelAll() }
            for _ in 0..<2 {
                group.addTask { await harness.importer.importImage(image) }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(1))
                throw Timeout.duplicateDidNotFinish
            }
            let result = try await group.next()
            #expect(result == .some(nil))
        }
        #expect(harness.writes == 0)
        harness.index.synchronize([])
        #expect(await harness.importer.importImage(image) != nil)
    }

    @MainActor
    private final class Harness {
        let folder: ImageTestFolder
        let index = ShelfImageIndex()
        var references: [ShelfImageReference] = []
        var writes = 0
        var insertions = 0
        var importsEnabled = true
        var saveFails = false
        var insertFails = false
        lazy var importer = ClipboardImageImporter(
            index: index,
            save: { [unowned self] data in
                writes += 1
                guard !saveFails else { return nil }
                return try? folder.write(data, name: "saved-\(writes).png")
            },
            insert: { [unowned self] url, fingerprint in
                insertions += 1
                guard !insertFails else { return false }
                let item = ShelfImageReference(id: UUID(), url: url)
                references.append(item)
                index.synchronize(references, known: [item.id: fingerprint])
                return true
            },
            rollback: { url in try? FileManager.default.removeItem(at: url) },
            isEnabled: { [unowned self] in importsEnabled }
        )

        init() throws { folder = try ImageTestFolder() }
        func removeAll() { references.removeAll(); index.synchronize([]) }
    }

    @Test func duplicateIsRejectedBeforeAnyAdditionalFileOrInsertion() async throws {
        let harness = try Harness()
        defer { harness.folder.remove() }
        let data = try ImageFixtures.image()
        #expect(await harness.importer.importImage(data) != nil)
        #expect(await harness.importer.importImage(data) == nil)
        let tiff = try ImageFixtures.image(type: .tiff)
        #expect(await harness.importer.importImage(tiff) == nil)
        #expect(harness.writes == 1)
        #expect(harness.insertions == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.folder.url.path).count == 1)
    }

    @Test func distinctImagesAndReimportAfterRemovalAreAccepted() async throws {
        let harness = try Harness()
        defer { harness.folder.remove() }
        let first = try ImageFixtures.image()
        let second = try ImageFixtures.image(width: 1, height: 4)
        #expect(await harness.importer.importImage(first) != nil)
        #expect(await harness.importer.importImage(second) != nil)
        #expect(await harness.importer.importImage(first) == nil)
        harness.removeAll()
        // Old files remain on disk, but no longer participate in deduplication.
        #expect(await harness.importer.importImage(first) != nil)
        #expect(harness.writes == 3)
    }

    @Test func concurrentImportsCreateAtMostOneFile() async throws {
        let harness = try Harness()
        defer { harness.folder.remove() }
        let data = try ImageFixtures.image()
        async let first = harness.importer.importImage(data)
        async let second = harness.importer.importImage(data)
        let results = await [first, second]
        #expect(results.compactMap { $0 }.count == 1)
        #expect(harness.writes == 1)
        #expect(harness.insertions == 1)
    }

    @Test func persistenceFailureDoesNotReserveFingerprint() async throws {
        let harness = try Harness()
        defer { harness.folder.remove() }
        let data = try ImageFixtures.image()
        harness.saveFails = true
        #expect(await harness.importer.importImage(data) == nil)
        #expect(harness.insertions == 0)
        harness.saveFails = false
        #expect(await harness.importer.importImage(data) != nil)
        #expect(harness.writes == 2)
    }

    @Test func insertionFailureRollsBackOnlyTheNewFile() async throws {
        let harness = try Harness()
        defer { harness.folder.remove() }
        let data = try ImageFixtures.image()
        let existing = try harness.folder.write(data, name: "user-file.png")
        harness.insertFails = true
        #expect(await harness.importer.importImage(data) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.folder.url.path) == ["user-file.png"])
        #expect(try Data(contentsOf: existing) == data)
        harness.insertFails = false
        #expect(await harness.importer.importImage(data) != nil)
    }

    @Test func invalidImagesAreNotPersisted() async throws {
        let harness = try Harness()
        defer { harness.folder.remove() }
        #expect(await harness.importer.importImage(Data("invalid".utf8)) == nil)
        #expect(harness.writes == 0)
        #expect(harness.insertions == 0)
    }

    @Test func preferenceIsRevalidatedAfterDeferredIndexing() async throws {
        let harness = try Harness()
        defer { harness.folder.remove() }
        let data = try ImageFixtures.image()
        harness.index.restore([.init(id: UUID(), url: URL(fileURLWithPath: "/legacy.png"))], cache: [:])
        let pending = Task { await harness.importer.importImage(data) }
        for _ in 0..<5 { await Task.yield() }
        harness.importsEnabled = false
        harness.index.synchronize([])
        #expect(await pending.value == nil)
        #expect(harness.writes == 0)
    }
}
