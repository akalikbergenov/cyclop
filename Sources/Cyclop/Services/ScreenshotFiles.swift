import Darwin
import Foundation

/// Screenshots, not arbitrary images. macOS supplies a screen-capture flag;
/// Cyclop marks new clipboard captures itself. Older vault files have neither,
/// so only their exact generated name, vault location and PNG signature count.
struct ScreenshotFiles {
    struct FileIdentity: Codable, Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    private static let marker = "com.cyclop.clipboard-screenshot"
    private static let nativeMarker = "com.apple.metadata:kMDItemIsScreenCapture"
    private static let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    private let legacyFolders: [URL]
    private let trash: (URL) throws -> Void

    init(
        legacyFolders: [URL],
        trash: @escaping (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.legacyFolders = legacyFolders.map(\.standardizedFileURL)
        self.trash = trash
    }

    @discardableResult
    func markScreenshot(_ url: URL) -> Bool {
        guard Self.fileIdentity(of: url) != nil, isPNG(url) else { return false }
        var version: UInt8 = 1
        return url.path.withCString { path in
            setxattr(path, Self.marker, &version, 1, 0, XATTR_NOFOLLOW) == 0
        }
    }

    func isScreenshot(_ url: URL) -> Bool {
        guard Self.fileIdentity(of: url) != nil else { return false }
        if attribute(Self.marker, at: url) == Data([1]) { return true }
        if let data = attribute(Self.nativeMarker, at: url),
           let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           value as? Bool == true { return true }

        guard legacyFolders.contains(url.deletingLastPathComponent().standardizedFileURL) else { return false }
        let pattern = #"^(?:Screenshot [0-9]{4}-[0-9]{2}-[0-9]{2} at |Снимок [0-9]{4}-[0-9]{2}-[0-9]{2} в )[0-9]{2}\.[0-9]{2}\.[0-9]{2}(?: \([0-9]+\))?\.png$"#
        return url.lastPathComponent.range(of: pattern, options: .regularExpression) != nil && isPNG(url)
    }

    func trashIfScreenshot(_ url: URL) throws {
        guard isScreenshot(url) else { return }
        do {
            try trash(url)
        } catch let error as NSError {
            // A file already removed elsewhere needs no second deletion.
            if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return }
            if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return }
            throw error
        }
    }

    static func fileIdentity(of url: URL) -> FileIdentity? {
        guard url.isFileURL else { return nil }
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    private func isPNG(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 8)) == Self.pngSignature
    }

    private func attribute(_ name: String, at url: URL) -> Data? {
        url.path.withCString { path in
            let count = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard count > 0, count <= 4096 else { return nil }
            var data = Data(count: count)
            let actual = data.withUnsafeMutableBytes {
                getxattr(path, name, $0.baseAddress, count, 0, XATTR_NOFOLLOW)
            }
            return actual == count ? data : nil
        }
    }
}
