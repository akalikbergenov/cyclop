import Darwin
import Foundation
import Testing
@testable import Cyclop

@MainActor
private struct ScreenshotRemovalFixture {
    let folder: URL
    let vault: URL
    let trash: URL
    let defaults: UserDefaults
    let suite = "cyclop-screenshot-tests-\(UUID())"
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==")!

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("cyclop-removal-\(UUID())")
        vault = folder.appendingPathComponent("Cyclop")
        trash = folder.appendingPathComponent("Test Trash")
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    func write(_ name: String, in location: URL? = nil, data: Data = Self.png) throws -> URL {
        let file = (location ?? folder).appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    func files() -> ScreenshotFiles {
        ScreenshotFiles(legacyFolders: [vault], trash: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
    }

    func nativeScreenshot(_ url: URL, value: Bool = true) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let result = data.withUnsafeBytes { bytes in
            url.path.withCString { path in
                setxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
        }
        #expect(result == 0)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}

@MainActor
struct ScreenshotRemovalConfigTests {
    @Test func defaultsToOffAndLoadsOlderConfiguration() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let file = try f.write("config.json", data: Data(#"{"saveClipboardImages":false}"#.utf8))
        let config = ConfigStore(file: file, defaults: f.defaults)
        #expect(!config.trashScreenshotsOnRemoval)
        #expect(!config.saveClipboardImages)
        #expect(!config.fileBroken)
    }

    @Test func settingSurvivesRestartAndCanBeDisabled() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let file = f.folder.appendingPathComponent("config.json")
        let config = ConfigStore(file: file, defaults: f.defaults)
        #expect(!config.trashScreenshotsOnRemoval)
        config.trashScreenshotsOnRemoval = true
        let restored = ConfigStore(file: file, defaults: f.defaults)
        #expect(restored.trashScreenshotsOnRemoval)
        restored.trashScreenshotsOnRemoval = false
        #expect(!ConfigStore(file: file, defaults: f.defaults).trashScreenshotsOnRemoval)
    }

    @Test func brokenConfigurationIsNotOverwritten() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let broken = Data("{broken".utf8)
        let file = try f.write("config.json", data: broken)
        let config = ConfigStore(file: file, defaults: f.defaults)
        #expect(config.fileBroken)
        #expect(!config.trashScreenshotsOnRemoval)
        config.trashScreenshotsOnRemoval = true
        #expect(try Data(contentsOf: file) == broken)
    }
}

@MainActor
struct ScreenshotRecognitionTests {
    @Test func nativeScreenshotsAndNewCyclopScreenshotsAreRecognized() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let native = try f.write("renamed-screen.png")
        try f.nativeScreenshot(native)
        let saved = try f.write("new-clipboard.png", in: f.vault)
        let files = f.files()
        #expect(files.markScreenshot(saved))
        #expect(files.isScreenshot(native))
        #expect(files.isScreenshot(saved))
        try files.trashIfScreenshot(native)
        #expect(!FileManager.default.fileExists(atPath: native.path))
        #expect(FileManager.default.fileExists(atPath: f.trash.appendingPathComponent(native.lastPathComponent).path))
    }

    @Test func oldCyclopScreenshotsAreRecognizedInBothLanguagesAndFallbackFolder() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let fallback = f.folder.appendingPathComponent("Support Screenshots")
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        let files = ScreenshotFiles(legacyFolders: [f.vault, fallback])
        for folder in [f.vault, fallback] {
            for name in ["Screenshot 2026-11-24 at 19.05.45.png", "Снимок 2026-11-24 в 19.05.45 (10).png"] {
                #expect(files.isScreenshot(try f.write(name, in: folder)))
            }
        }
    }

    @Test func photosDocumentsAndUnmarkedImagesAreLeftAlone() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let files = f.files()
        let photo = try f.write("photo.png", in: f.vault)
        try f.nativeScreenshot(photo, value: false)
        let ordinary = try f.write("photo.jpg")
        let similarName = try f.write("Screenshot 2026-11-24 at 19.05.45.png") // outside vault
        let document = try f.write("notes.txt", data: Data("keep me".utf8))
        let fakePNG = try f.write("Screenshot 2026-11-24 at 19.05.45.png", in: f.vault, data: Data("not PNG".utf8))
        for file in [photo, ordinary, similarName, document, fakePNG] {
            #expect(!files.isScreenshot(file))
            try files.trashIfScreenshot(file)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.path).isEmpty)
    }

    @Test func symlinksAreNeverFollowedOrTrashed() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let original = try f.write("screen.png")
        try f.nativeScreenshot(original)
        let link = f.vault.appendingPathComponent("Screenshot 2026-11-24 at 19.05.45.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(!f.files().isScreenshot(link))
        try f.files().trashIfScreenshot(link)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == original.path)
    }
}

@MainActor
struct ScreenshotShelfRemovalTests {
    @Test(arguments: [false, true])
    func replacingFileAtLiveCardPathNeverTrashesReplacement(afterRestart: Bool) throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let file = try f.write("Screenshot 2026-11-24 at 19.05.45.png", in: f.vault)
        let files = f.files()
        var shelf = ShelfStore(defaults: f.defaults, shouldTrashScreenshots: { true }, trashScreenshot: files.trashIfScreenshot)
        shelf.add([file])
        if afterRestart {
            shelf = ShelfStore(defaults: f.defaults, shouldTrashScreenshots: { true }, trashScreenshot: files.trashIfScreenshot)
            shelf.load()
        }
        let card = try #require(shelf.items.first)
        let moved = f.folder.appendingPathComponent("old-screen.png")
        try FileManager.default.moveItem(at: file, to: moved)
        try ScreenshotRemovalFixture.png.write(to: file)
        shelf.remove(card)
        #expect(shelf.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.path).isEmpty)
    }

    @Test func duplicateRestoredPathsDoNotBreakFileIdentityCache() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let file = try f.write("photo.png")
        f.defaults.set([file.path, file.path], forKey: "shelf.urls")
        let shelf = ShelfStore(defaults: f.defaults, shouldTrashScreenshots: { false })
        shelf.load()
        shelf.refreshFromDisk()
        #expect(shelf.items.count == 2)
        #expect(f.defaults.data(forKey: "shelf.fileIdentities.v1") != nil)
    }

    @Test func removingClipboardPhotoCopyDoesNotTouchOriginalPhoto() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let original = try f.write("photo.png")
        let copy = try f.write("Screenshot 2026-11-24 at 19.05.45.png", in: f.vault, data: Data(contentsOf: original))
        let files = f.files()
        #expect(files.markScreenshot(copy))
        let shelf = ShelfStore(defaults: f.defaults, shouldTrashScreenshots: { true }, trashScreenshot: files.trashIfScreenshot)
        shelf.add([original, copy])
        shelf.remove(try #require(shelf.items.first(where: { $0.url == copy })))
        #expect(shelf.items.map(\.url) == [original])
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(try Data(contentsOf: original) == ScreenshotRemovalFixture.png)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        shelf.remove(try #require(shelf.items.first))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: f.trash.appendingPathComponent(original.lastPathComponent).path))
    }

    @Test func disabledSettingOnlyRemovesCard() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let file = try f.write("screen.png")
        try f.nativeScreenshot(file)
        var trashCalls = 0
        let shelf = ShelfStore(defaults: f.defaults, shouldTrashScreenshots: { false }, trashScreenshot: { _ in trashCalls += 1 })
        shelf.add([file])
        shelf.remove(try #require(shelf.items.first))
        #expect(shelf.items.isEmpty)
        #expect(trashCalls == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func enabledSettingTrashesScreenshotButPreservesPhotoAndDocument() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let screen = try f.write("screen.png")
        try f.nativeScreenshot(screen)
        let photo = try f.write("photo.png")
        let document = try f.write("notes.txt", data: Data("keep".utf8))
        let files = f.files()
        let shelf = ShelfStore(defaults: f.defaults, shouldTrashScreenshots: { true }, trashScreenshot: files.trashIfScreenshot)
        shelf.add([screen, photo, document])
        shelf.clear()
        #expect(shelf.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: screen.path))
        #expect(FileManager.default.fileExists(atPath: photo.path))
        #expect(FileManager.default.fileExists(atPath: document.path))
    }

    @Test func failureKeepsScreenshotCardWhileClearRemovesOtherCards() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let screen = try f.write("screen.png")
        let document = try f.write("notes.txt", data: Data("keep".utf8))
        let shelf = ShelfStore(defaults: f.defaults, shouldTrashScreenshots: { true }, trashScreenshot: { url in
            if url == screen { throw CocoaError(.fileWriteNoPermission) }
        })
        shelf.add([screen, document])
        shelf.clear()
        #expect(shelf.items.map(\.url) == [screen])
        #expect(shelf.removalError != nil)
        #expect(f.defaults.stringArray(forKey: "shelf.urls") == [screen.path])
        shelf.dismissRemovalError()
        #expect(shelf.removalError == nil)
    }

    @Test func evictionAndMissingFileRefreshNeverTrashFiles() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        var trashCalls = 0
        let shelf = ShelfStore(defaults: f.defaults, shouldTrashScreenshots: { true }, trashScreenshot: { _ in trashCalls += 1 })
        var urls: [URL] = []
        for n in 0..<61 { urls.append(try f.write("screen-\(n).png")) }
        shelf.add(urls)
        #expect(shelf.items.count == 60)
        #expect(trashCalls == 0)
        #expect(FileManager.default.fileExists(atPath: urls[0].path))
        for url in urls { try FileManager.default.removeItem(at: url) }
        shelf.refreshFromDisk()
        #expect(shelf.items.isEmpty)
        #expect(trashCalls == 0)
    }

    @Test func removalWorksAfterRestoreAndUsesCurrentSetting() throws {
        let f = try ScreenshotRemovalFixture()
        defer { f.cleanUp() }
        let screen = try f.write("Screenshot 2026-11-24 at 19.05.45.png", in: f.vault)
        f.defaults.set([screen.path], forKey: "shelf.urls")
        var enabled = false
        let files = f.files()
        let shelf = ShelfStore(defaults: f.defaults, shouldTrashScreenshots: { enabled }, trashScreenshot: files.trashIfScreenshot)
        shelf.load()
        enabled = true
        let card = try #require(shelf.items.first)
        shelf.remove(card)
        #expect(shelf.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: screen.path))
        // A stale card must not cause a second removal attempt at a reused path.
        try ScreenshotRemovalFixture.png.write(to: screen)
        shelf.remove(card)
        #expect(FileManager.default.fileExists(atPath: screen.path))
    }
}
