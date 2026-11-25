import Foundation
import Testing
@testable import Cyclop

struct ImageTestFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("cyclop-images-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ data: Data, name: String = "image.png") throws -> URL {
        let file = url.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@MainActor
struct ShelfImageIndexTests {
    @Test func refreshKeepsDurableCacheUntilVerificationCompletes() async throws {
        let folder = try ImageTestFolder()
        defer { folder.remove() }
        let data = try ImageFixtures.image()
        let file = try folder.write(data)
        let fingerprint = try #require(ImageFingerprint(data: data))
        let reference = ShelfImageReference(id: UUID(), url: file)
        let index = ShelfImageIndex()
        index.synchronize([reference], known: [reference.id: fingerprint])
        index.refresh()
        #expect(index.snapshot[file.path]?.fingerprint == fingerprint)
        #expect(!index.canImport(fingerprint))
        #expect(await index.contains(fingerprint) == true)
    }

    @Test func removingOneReferenceDoesNotUnregisterAnother() async throws {
        let fingerprint = try #require(ImageFingerprint(data: ImageFixtures.image()))
        let first = ShelfImageReference(id: UUID(), url: URL(fileURLWithPath: "/first.png"))
        let second = ShelfImageReference(id: UUID(), url: URL(fileURLWithPath: "/second.png"))
        let index = ShelfImageIndex()
        index.synchronize([first, second], known: [first.id: fingerprint, second.id: fingerprint])
        #expect(await index.contains(fingerprint) == true)
        index.synchronize([second])
        #expect(await index.contains(fingerprint) == true)
        index.synchronize([])
        #expect(await index.contains(fingerprint) == false)
    }

    @Test func manuallyAddedImagesParticipateAndNonImagesDoNotBlock() async throws {
        let folder = try ImageTestFolder()
        defer { folder.remove() }
        let data = try ImageFixtures.image(type: .tiff)
        let image = try folder.write(data, name: "manual") // no extension
        let text = try folder.write(Data("hello".utf8), name: "note.txt")
        let fingerprint = try #require(ImageFingerprint(data: data))
        let index = ShelfImageIndex()
        index.synchronize([.init(id: UUID(), url: image), .init(id: UUID(), url: text)])
        #expect(await index.contains(fingerprint) == true)
        let other = try #require(ImageFingerprint(data: ImageFixtures.image(width: 1, height: 4)))
        #expect(await index.contains(other) == false)
    }

    @Test func restoreUsesCachedFingerprintsAndNewItemIDs() async throws {
        let fingerprint = try #require(ImageFingerprint(data: ImageFixtures.image()))
        let reference = ShelfImageReference(id: UUID(), url: URL(fileURLWithPath: "/do-not-read/image.png"))
        let original = ShelfImageIndex()
        original.synchronize([reference], known: [reference.id: fingerprint])
        let encoded = try JSONEncoder().encode(original.snapshot)
        let restored = ShelfImageIndex()
        restored.restore([.init(id: UUID(), url: reference.url)], cache: try JSONDecoder().decode(ShelfImageIndex.Snapshot.self, from: encoded))
        #expect(await restored.contains(fingerprint) == true)
    }

    @Test func legacyRestoreDefersReadsAndImportsUntilShelfIsOpened() async throws {
        let folder = try ImageTestFolder()
        defer { folder.remove() }
        let data = try ImageFixtures.image()
        let file = try folder.write(data)
        let fingerprint = try #require(ImageFingerprint(data: data))
        let index = ShelfImageIndex()
        index.restore([.init(id: UUID(), url: file)], cache: [:])
        var finished = false
        let lookup = Task { let result = await index.contains(fingerprint); finished = true; return result }
        for _ in 0..<5 { await Task.yield() }
        #expect(!finished)
        #expect(index.snapshot.isEmpty)
        index.refresh()
        #expect(await lookup.value == true)
    }

    @Test func missingFilesAreIgnoredAndUnreadableImagesFailClosed() async throws {
        let folder = try ImageTestFolder()
        defer { folder.remove() }
        let fingerprint = try #require(ImageFingerprint(data: ImageFixtures.image()))
        let index = ShelfImageIndex()
        index.synchronize([.init(id: UUID(), url: folder.url.appendingPathComponent("missing.png"))])
        #expect(await index.contains(fingerprint) == false)
        let corrupt = try folder.write(Data("broken PNG".utf8))
        index.synchronize([.init(id: UUID(), url: corrupt)])
        #expect(await index.contains(fingerprint) == nil)
    }

    @Test func removalDuringIndexingCannotRestoreStaleReferences() async throws {
        let folder = try ImageTestFolder()
        defer { folder.remove() }
        let data = try ImageFixtures.image()
        let file = try folder.write(data)
        let fingerprint = try #require(ImageFingerprint(data: data))
        let index = ShelfImageIndex()
        index.synchronize([.init(id: UUID(), url: file)])
        index.synchronize([])
        #expect(await index.contains(fingerprint) == false)
        for _ in 0..<5 { await Task.yield() }
        #expect(index.snapshot.isEmpty)
    }

    @Test func deferredLookupCanBeCancelledWithoutOpeningShelf() async throws {
        let fingerprint = try #require(ImageFingerprint(data: ImageFixtures.image()))
        let index = ShelfImageIndex()
        index.restore([.init(id: UUID(), url: URL(fileURLWithPath: "/deferred.png"))], cache: [:])
        let lookup = Task { await index.contains(fingerprint) }
        await Task.yield()
        lookup.cancel()
        #expect(await lookup.value == nil)
    }
}
