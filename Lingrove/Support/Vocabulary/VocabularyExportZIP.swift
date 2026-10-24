import Foundation
import zlib

/// PNG is already compressed, so a bounded ZIP using stored entries adds no compression job
/// or subprocess. Only app-generated relative filenames enter the archive. The caller runs on
/// the notebook actor; CRC pointers are borrowed only for the duration of each C call.
nonisolated enum VocabularyExportZIP {
    static func data(_ package: VocabularyExportPackage) throws -> Data {
        let files = [(package.dataFilename, package.data)] + package.images.keys.sorted().compactMap { name in
            package.images[name].map { ("images/" + name, $0) }
        }
        guard files.count <= 10_000, files.allSatisfy({ validPath($0.0) }),
              files.reduce(0, { $0 + $1.1.count }) <= VocabularyArchive.maximumBackupBytes else { throw VocabularyExportError.tooLarge }
        var output = Data(), central = Data()
        output.reserveCapacity(files.reduce(0) { $0 + $1.1.count } + files.count * 200)
        for (path, data) in files {
            try Task.checkCancellation()
            let name = Data(path.utf8), offset = UInt32(output.count), size = UInt32(data.count)
            let checksum = data.withUnsafeBytes { bytes in
                UInt32(truncatingIfNeeded: crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
            }
            output.appendLE(UInt32(0x04034b50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0x21))
            output.appendLE(checksum); output.appendLE(size); output.appendLE(size)
            output.appendLE(UInt16(name.count)); output.appendLE(UInt16(0)); output.append(name); output.append(data)
            central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(20)); central.appendLE(UInt16(20))
            for value in [UInt16(0), 0, 0, 0x21] { central.appendLE(value) }
            central.appendLE(checksum); central.appendLE(size); central.appendLE(size); central.appendLE(UInt16(name.count))
            for _ in 0..<4 { central.appendLE(UInt16(0)) }
            central.appendLE(UInt32(0)); central.appendLE(offset); central.append(name)
        }
        let offset = UInt32(output.count)
        output.append(central); output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
        output.appendLE(UInt16(files.count)); output.appendLE(UInt16(files.count))
        output.appendLE(UInt32(central.count)); output.appendLE(offset); output.appendLE(UInt16(0))
        guard output.count <= VocabularyArchive.maximumBackupBytes else { throw VocabularyExportError.tooLarge }
        return output
    }

    private static func validPath(_ path: String) -> Bool {
        if ["Lingrove-vocabulary.txt", "Lingrove-vocabulary.csv", "Lingrove-vocabulary.json"].contains(path) { return true }
        guard path.hasPrefix("images/lg-image-"), path.hasSuffix(".png") else { return false }
        let digest = path.dropFirst("images/lg-image-".count).dropLast(4)
        return digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

private extension Data {
    /// A local little-endian copy keeps a pointer from escaping Swift's borrowed integer storage.
    nonisolated mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
