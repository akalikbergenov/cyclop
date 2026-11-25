import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Cyclop

enum ImageFixtures {
    static func image(
        width: Int = 2, height: Int = 2,
        pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                           0, 0, 255, 255, 255, 255, 255, 255],
        type: UTType = .png, orientation: Int = 1
    ) throws -> Data {
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let bitmap = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, bitmap, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

struct ImageFingerprintTests {
    @Test func identicalPixelsProduceDeterministicSHA256() throws {
        let image = try ImageFixtures.image()
        let first = try #require(ImageFingerprint(data: image))
        #expect(first == ImageFingerprint(data: image))
        #expect(first.digest.count == 64)
    }

    @Test func losslessPNGAndTIFFHaveTheSameIdentity() throws {
        let png = try ImageFixtures.image()
        let tiff = try ImageFixtures.image(type: .tiff)
        #expect(png != tiff)
        let fingerprint = try #require(ImageFingerprint(data: png))
        #expect(fingerprint == ImageFingerprint(data: tiff))
    }

    @Test func onePixelDifferenceIsNotADuplicate() throws {
        let original = try ImageFixtures.image()
        let changed = try ImageFixtures.image(pixels: [254, 0, 0, 255, 0, 255, 0, 255,
                                                       0, 0, 255, 255, 255, 255, 255, 255])
        let fingerprint = try #require(ImageFingerprint(data: original))
        #expect(fingerprint != ImageFingerprint(data: changed))
    }

    @Test func dimensionsParticipateInIdentity() throws {
        let square = try ImageFixtures.image()
        let row = try ImageFixtures.image(width: 4, height: 1)
        let fingerprint = try #require(ImageFingerprint(data: square))
        #expect(fingerprint != ImageFingerprint(data: row))
    }

    @Test func orientationIsAppliedBeforeHashing() throws {
        let redBlue = try ImageFixtures.image(width: 2, height: 1,
                                               pixels: [255, 0, 0, 255, 0, 0, 255, 255], type: .tiff, orientation: 3)
        let blueRed = try ImageFixtures.image(width: 2, height: 1,
                                               pixels: [0, 0, 255, 255, 255, 0, 0, 255])
        let fingerprint = try #require(ImageFingerprint(data: redBlue))
        #expect(fingerprint == ImageFingerprint(data: blueRed))
    }

    @Test func invalidDataHasNoFingerprint() {
        #expect(ImageFingerprint(data: Data()) == nil)
        #expect(ImageFingerprint(data: Data("not an image".utf8)) == nil)
    }
}
