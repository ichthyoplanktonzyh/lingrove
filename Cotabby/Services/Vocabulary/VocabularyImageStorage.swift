import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The archive actor owns this value and serializes all disk mutations. Imports normalize to a
/// bounded PNG, removing external paths and source metadata. No file is copied until a notebook
/// transaction actually references it; immutable hash names let retries reuse the same bytes.
nonisolated struct VocabularyImageStorage {
    let directory: URL?
    private var memory: [String: Data] = [:]

    init(notebook: URL?) {
        directory = notebook.map { $0.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent + ".media") }
    }

    static func prepare(_ data: Data) throws -> VocabularyPreparedImage {
        guard data.count <= 24 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30_000, height <= 30_000, width * height <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: VocabularyContentPolicy.maximumDimension
              ] as CFDictionary) else { throw VocabularyError.invalidContent }
        let output = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw VocabularyError.invalidContent
        }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target), output.length <= VocabularyContentPolicy.maximumImageBytes else {
            throw VocabularyError.invalidContent
        }
        let bytes = output as Data
        return .init(reference: .init(digest: digest(bytes), width: image.width, height: image.height, byteCount: bytes.count), data: bytes)
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Read through one regular-file descriptor with an enforced byte ceiling. A file selected
    /// in an open panel can change after stat; checking only its earlier size does not bound IO.
    static func boundedRead(_ url: URL, maximum: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw VocabularyError.invalidContent }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw VocabularyError.invalidContent }
        guard info.st_size <= maximum else { throw VocabularyError.oversizedArchive }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximum + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximum else { throw VocabularyError.oversizedArchive }
        }
        return data
    }

    static func validate(_ data: Data, reference: VocabularyImageReference) throws {
        guard VocabularyContentPolicy.valid(reference), data.count == reference.byteCount,
              digest(data) == reference.digest, data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              props[kCGImagePropertyPixelWidth] as? Int == reference.width,
              props[kCGImagePropertyPixelHeight] as? Int == reference.height else { throw VocabularyError.invalidContent }
    }

    func read(_ image: VocabularyImageReference) throws -> Data {
        guard VocabularyContentPolicy.valid(image) else { throw VocabularyError.invalidContent }
        let data: Data
        if let directory {
            let url = directory.appendingPathComponent(image.filename)
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
            guard values.fileSize == image.byteCount, values.isRegularFile == true, values.isSymbolicLink != true else {
                throw VocabularyError.invalidContent
            }
            data = try Self.boundedRead(url, maximum: VocabularyContentPolicy.maximumImageBytes)
        } else {
            guard let bytes = memory[image.filename] else { throw VocabularyError.invalidContent }; data = bytes
        }
        try Self.validate(data, reference: image)
        return data
    }

    /// Return whether this transaction created a file so a failed notebook commit can roll back
    /// only its own writes. Existing shared media must survive unrelated failures and retries.
    mutating func write(_ data: Data, image: VocabularyImageReference) throws -> Bool {
        try Self.validate(data, reference: image)
        if (try? read(image)) != nil { return false }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw VocabularyError.invalidContent }
            let target = directory.appendingPathComponent(image.filename)
            let existed = FileManager.default.fileExists(atPath: target.path)
            if existed {
                let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VocabularyError.invalidContent }
            }
            // A verified backup may repair a damaged file with the same immutable identity.
            // This also repairs the old notebook if its later JSON replacement fails. Never
            // roll back that repair by deleting a resource that was already present.
            try data.write(to: target, options: .atomic)
            do { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path) } catch {
                if !existed { try? FileManager.default.removeItem(at: target) }; throw error
            }
            return !existed
        } else { memory[image.filename] = data }
        return true
    }

    mutating func remove(_ image: VocabularyImageReference) {
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(image.filename)) }
        memory.removeValue(forKey: image.filename)
    }
}
