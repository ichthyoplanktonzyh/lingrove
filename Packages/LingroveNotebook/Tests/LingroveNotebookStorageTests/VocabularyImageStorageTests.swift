import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
import LingroveNotebook
import LingroveNotebookStorage

/// Image storage accepts bounded image bytes and owns them by notebook path. These synthetic pixels
/// exercise ImageIO and disk isolation without requiring a photo provider or user-selected media.
struct VocabularyImageStorageTests {
    @Test func preparedPNGIsValidatedAndStoredOnlyForItsNotebook() throws {
        let prepared = try VocabularyImageStorage.prepare(Self.syntheticPNG())
        #expect(prepared.reference.width == 3)
        #expect(prepared.reference.height == 2)
        try VocabularyImageStorage.validate(prepared.data, reference: prepared.reference)

        var corrupted = prepared.data
        corrupted.append(0)
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyImageStorage.validate(corrupted, reference: prepared.reference)
        }
        #expect(throws: VocabularyError.invalidContent) {
            _ = try VocabularyImageStorage.prepare(Data("not an image".utf8))
        }

        let directory = try VocabularyStorageTestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var firstNotebook = VocabularyImageStorage(notebook: directory.appendingPathComponent("first.sqlite"))
        let secondNotebook = VocabularyImageStorage(notebook: directory.appendingPathComponent("second.sqlite"))

        #expect(try firstNotebook.write(prepared.data, image: prepared.reference))
        #expect(!(try firstNotebook.write(prepared.data, image: prepared.reference)))
        #expect(try firstNotebook.read(prepared.reference) == prepared.data)
        #expect(throws: (any Error).self) { _ = try secondNotebook.read(prepared.reference) }

        firstNotebook.remove(prepared.reference)
        #expect(throws: (any Error).self) { _ = try firstNotebook.read(prepared.reference) }
    }

    private static func syntheticPNG() throws -> Data {
        guard let context = CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VocabularyError.invalidContent
        }
        context.setFillColor(CGColor(srgbRed: 0.12, green: 0.48, blue: 0.78, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        guard let image = context.makeImage() else { throw VocabularyError.invalidContent }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw VocabularyError.invalidContent
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VocabularyError.invalidContent }
        return output as Data
    }
}
