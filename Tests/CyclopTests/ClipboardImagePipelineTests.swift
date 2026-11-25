import AppKit
import Foundation
import Testing
@testable import Cyclop

@MainActor
struct ClipboardImagePipelineTests {
    @Test func invalidTIFFStillRetriesThenRecordsAccompanyingText() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = ClipboardStore(pasteboard: board)
        var imageEvents = 0
        var writes = 0
        let importer = ClipboardImageImporter(index: ShelfImageIndex(), save: { _ in
            writes += 1
            return nil
        }, insert: { _, _ in false }, rollback: { _ in })
        clipboard.onImage = { data, onInvalidImage in
            imageEvents += 1
            Task { await importer.importImage(data, onInvalidImage: onInvalidImage) }
        }
        board.clearContents()
        #expect(board.setData(Data("invalid TIFF".utf8), forType: .tiff))
        #expect(board.setString("keep this text", forType: .string))
        clipboard.poll()
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        while clipboard.items.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(imageEvents > 1)
        #expect(writes == 0)
        #expect(clipboard.items.first?.payload == .text("keep this text"))
    }

    @Test func duplicateEventsAreProcessedWithoutChangingPasteboardOrCreatingFiles() async throws {
        let folder = try ImageTestFolder()
        defer { folder.remove() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = ClipboardStore(pasteboard: board)
        let index = ShelfImageIndex()
        var references: [ShelfImageReference] = []
        var writes = 0
        let importer = ClipboardImageImporter(index: index, save: { data in
            writes += 1
            return try? folder.write(data, name: "\(writes).png")
        }, insert: { url, fingerprint in
            let item = ShelfImageReference(id: UUID(), url: url)
            references.append(item)
            index.synchronize(references, known: [item.id: fingerprint])
            return true
        }, rollback: { url in try? FileManager.default.removeItem(at: url) })
        var imports: [Task<URL?, Never>] = []
        clipboard.onImage = { data, failed in
            imports.append(Task { await importer.importImage(data, onInvalidImage: failed) })
        }
        let image = try ImageFixtures.image()

        board.clearContents()
        board.setData(image, forType: .png)
        clipboard.poll()
        #expect(await imports[0].value != nil)
        clipboard.poll() // unchanged counter
        #expect(imports.count == 1)

        board.clearContents()
        board.setString("temporary text", forType: .string)
        clipboard.poll()
        #expect(clipboard.items.first?.payload == .text("temporary text"))

        board.clearContents()
        board.setData(image, forType: .png)
        let changeCount = board.changeCount
        let types = board.types
        clipboard.poll()
        #expect(await imports[1].value == nil)
        #expect(board.changeCount == changeCount)
        #expect(board.types == types)
        #expect(board.data(forType: .png) == image) // still available to paste
        #expect(writes == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.url.path).count == 1)

        references.removeAll()
        index.synchronize([])
        clipboard.poll() // removal does not reprocess the unchanged clipboard
        #expect(imports.count == 2)
        #expect(writes == 1)

        board.clearContents()
        board.setData(image, forType: .png)
        clipboard.poll()
        #expect(await imports[2].value != nil)
        #expect(writes == 2)
    }

    @Test func tiffClipboardDataIsSavedAsPNGWithTheSameNormalizedIdentity() async throws {
        let folder = try ImageTestFolder()
        defer { folder.remove() }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = ClipboardStore(pasteboard: board)
        let tiff = try ImageFixtures.image(type: .tiff, orientation: 3)
        var captured: Data?
        clipboard.onImage = { data, _ in captured = data }
        board.clearContents()
        #expect(board.setData(tiff, forType: .tiff))
        clipboard.poll()
        let image = try #require(captured)
        let png = try #require(ImageFingerprint.pngData(from: image))
        #expect(png.starts(with: [137, 80, 78, 71]))
        let originalFingerprint = try #require(ImageFingerprint(data: tiff))
        #expect(ImageFingerprint(data: png) == originalFingerprint)
    }

    @Test func fileURLsStillWinOverImageDataAndImagePreferenceIsRespected() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let clipboard = ClipboardStore(pasteboard: board)
        var imageEvents = 0
        clipboard.onImage = { _, _ in imageEvents += 1 }
        let file = URL(fileURLWithPath: "/example.png")
        board.clearContents()
        #expect(board.writeObjects([file as NSURL]))
        board.setData(try ImageFixtures.image(), forType: .png)
        clipboard.poll()
        #expect(clipboard.items.first?.payload == .file(file))
        #expect(imageEvents == 0)
        clipboard.wantsImages = { false }
        board.clearContents()
        board.setData(try ImageFixtures.image(), forType: .png)
        clipboard.poll()
        #expect(imageEvents == 0)
    }
}

@MainActor
struct ShelfImageLifecycleTests {
    @Test func storeSynchronizesAddRemoveClearReloadAndCache() async throws {
        let folder = try ImageTestFolder()
        defer { folder.remove() }
        let suite = "cyclop-image-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = try ImageFixtures.image()
        let first = try folder.write(image, name: "first.png")
        let second = try folder.write(image, name: "second.png")
        let fingerprint = try #require(ImageFingerprint(data: image))
        let shelf = ShelfStore(defaults: defaults)
        shelf.add([first, second])
        #expect(await shelf.imageIndex.contains(fingerprint) == true)
        // Wait for both references, not merely the first positive match.
        let unrelated = try #require(ImageFingerprint(data: ImageFixtures.image(width: 4, height: 1)))
        #expect(await shelf.imageIndex.contains(unrelated) == false)
        shelf.remove(try #require(shelf.items.first(where: { $0.url == first })))
        #expect(await shelf.imageIndex.contains(fingerprint) == true)

        let restored = ShelfStore(defaults: defaults)
        restored.load()
        #expect(restored.items.map(\.url) == [second])
        #expect(await restored.imageIndex.contains(fingerprint) == true)
        restored.clear()
        #expect(await restored.imageIndex.contains(fingerprint) == false)
        #expect(defaults.stringArray(forKey: "shelf.urls") == [])
    }

    @Test func restoredLegacyCardsWaitForRefreshAndMissingCardsAreUnregistered() async throws {
        let folder = try ImageTestFolder()
        defer { folder.remove() }
        let suite = "cyclop-image-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try ImageFixtures.image()
        let file = try folder.write(data)
        defaults.set([file.path], forKey: "shelf.urls")
        let shelf = ShelfStore(defaults: defaults)
        shelf.load()
        #expect(shelf.imageIndex.snapshot.isEmpty)
        shelf.refreshFromDisk()
        let fingerprint = try #require(ImageFingerprint(data: data))
        #expect(await shelf.imageIndex.contains(fingerprint) == true)
        try FileManager.default.removeItem(at: file)
        shelf.refreshFromDisk()
        #expect(shelf.items.isEmpty)
        #expect(await shelf.imageIndex.contains(fingerprint) == false)
    }
}
