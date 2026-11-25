import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Exact equality after ImageIO orientation and conversion to sRGB, RGBA8,
/// premultiplied alpha, big-endian component order. No scaling or metadata.
struct ImageFingerprint: Hashable, Codable, Sendable {
    let digest: String

    init?(data: Data) {
        guard let image = Self.orientedImage(data),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let (rowBytes, rowOverflow) = image.width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: image.height)
        guard !rowOverflow, !sizeOverflow, byteCount > 0 else { return nil }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ), let pixels = context.data else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var hash = SHA256()
        let dimensions = [UInt64(image.width).bigEndian, UInt64(image.height).bigEndian]
        dimensions.withUnsafeBytes { hash.update(bufferPointer: $0) }
        hash.update(bufferPointer: UnsafeRawBufferPointer(start: pixels, count: byteCount))
        digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Vault files keep their existing PNG format. Preserve original PNG bytes;
    /// TIFF is converted only after the first duplicate check, off the UI thread.
    static func pngData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if CGImageSourceGetType(source) == UTType.png.identifier as CFString { return data }
        guard let image = orientedImage(data) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return png as Data
    }

    private static func orientedImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                // The original's longest side: apply orientation, never resize.
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary)
    }
}
