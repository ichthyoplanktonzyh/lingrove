//
//  MDictReader.swift
//  Easydict
//
//  Created by Kuroda Kayn on 2026/05/01.
//  Copyright © 2026 izual. All rights reserved.
//

import Foundation

// MARK: - MDictError

/// Errors produced when parsing or querying MDict (MDX/MDD) files.
enum MDictError: LocalizedError {
    case invalidFormat(String)
    case unsupportedCompression(UInt32)
    case decompressionFailed
    case encodingError
    case encrypted

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case let .invalidFormat(detail):
            return "Invalid MDict format: \(detail)"
        case let .unsupportedCompression(type):
            return "Unsupported compression type \(type); only LZO (1), zlib (2), and none (0) are supported"
        case .decompressionFailed:
            return "Failed to decompress data block"
        case .encodingError:
            return "Failed to decode text with the specified encoding"
        case .encrypted:
            return "Encrypted MDict files are not supported"
        }
    }
}

let maxMDictDecompressedBlockSize = 32 * 1024 * 1024
let maxMDictMetadataSize = 16 * 1024 * 1024
let maxMDictBlockCount = 200_000
let maxMDictEntryCount = 20_000_000
let maxMDictRecordSize = 8 * 1024 * 1024
let maxMDictResultBytes = 16 * 1024 * 1024
let maxMDictCachedKeyBlockCount = 4
let maxMDictCachedRecordBlockCount = 8
let maxMDictCachedRecordBlockBytes = 50 * 1024 * 1024

// MARK: - MDictHeader

/// Parsed metadata from the MDict file header XML.
struct MDictHeader: Codable {
    // MARK: Lifecycle

    init(
        version: Double,
        title: String,
        description: String,
        encoding: String.Encoding,
        format: String,
        keyCaseSensitive: Bool,
        encrypted: Int
    ) {
        self.version = version
        self.title = title
        self.description = description
        self.encoding = encoding
        self.format = format
        self.keyCaseSensitive = keyCaseSensitive
        self.encrypted = encrypted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Double.self, forKey: .version)
        self.title = try container.decode(String.self, forKey: .title)
        self.description = try container.decode(String.self, forKey: .description)
        let encodingRawValue = try container.decode(UInt.self, forKey: .encodingRawValue)
        self.encoding = String.Encoding(rawValue: encodingRawValue)
        self.format = try container.decode(String.self, forKey: .format)
        self.keyCaseSensitive = try container.decode(Bool.self, forKey: .keyCaseSensitive)
        self.encrypted = try container.decode(Int.self, forKey: .encrypted)
    }

    // MARK: Internal

    enum CodingKeys: CodingKey {
        case version
        case title
        case description
        case encodingRawValue
        case format
        case keyCaseSensitive
        case encrypted
    }

    let version: Double
    let title: String
    let description: String
    let encoding: String.Encoding
    let format: String
    let keyCaseSensitive: Bool
    /// Raw value of the `Encrypted` attribute: 0 = none, 1 = key header (RegCode required), 2 = key index.
    let encrypted: Int

    var isHTML: Bool { format.lowercased().contains("html") }

    var nullTerminatorSize: Int {
        encoding == .utf16LittleEndian || encoding == .utf16BigEndian ? 2 : 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(encoding.rawValue, forKey: .encodingRawValue)
        try container.encode(format, forKey: .format)
        try container.encode(keyCaseSensitive, forKey: .keyCaseSensitive)
        try container.encode(encrypted, forKey: .encrypted)
    }
}

// MARK: - MDictKeyEntry

/// A single key-to-record mapping extracted from the key block section.
struct MDictKeyEntry {
    let word: String
    let recordOffset: UInt64
    let globalIndex: Int
}

// MARK: - MDictKeyBlockRange

/// Metadata for one compressed key block.
///
/// MDict stores the first and last key in key block info. Keeping those
/// boundaries lets lookup skip full key parsing until a query lands in a
/// candidate block.
struct MDictKeyBlockRange: Codable {
    let firstKey: String
    let lastKey: String
    let compressedStart: Int
    let compressedSize: Int
    let decompressedSize: Int
    let entryStartIndex: Int
    let entryCount: Int

    var entryEndIndex: Int {
        entryStartIndex + entryCount
    }
}

// MARK: - RecordBlockInfo

/// Compressed and decompressed sizes for one record block.
struct RecordBlockInfo: Codable {
    let compressedSize: UInt64
    let decompressedSize: UInt64
}

// MARK: - RecordBlockRange

/// Precomputed byte ranges for a decompressed record block.
///
/// Keeping cumulative compressed and decompressed offsets avoids rescanning all
/// preceding blocks for every lookup. The reader uses this table to binary
/// search the containing block and read the matching compressed bytes directly.
struct RecordBlockRange: Codable {
    let info: RecordBlockInfo
    let compressedStart: Int
    let decompressedStart: UInt64

    var decompressedEnd: UInt64 {
        decompressedStart + info.decompressedSize
    }
}

// MARK: - RecordSpan

/// Offset and length for a single dictionary record.
///
/// This value is cheap to hash, letting duplicate headword records be filtered
/// before reading and hashing large definition payloads.
struct RecordSpan: Hashable {
    let offset: UInt64
    let size: Int
}

// MARK: - MDictReader

/// Reads and parses MDict binary files (MDX for definitions, MDD for resources).
///
/// Supports format versions 1.x and 2.x with LZO, zlib, or uncompressed data blocks.
/// Keeps key block boundaries on init, then parses matching key blocks and
/// decompresses record blocks on demand.
final class MDictReader {
    // MARK: Lifecycle

    init(url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, UInt64(size) <= 8 * 1024 * 1024 * 1024 else {
            throw MDictError.invalidFormat("File size is outside the supported limit")
        }
        let data = try Data(contentsOf: url, options: [.alwaysMapped])
        self.data = data

        var cursor = 0
        self.header = try Self.parseHeader(data, cursor: &cursor)

        if header.encrypted & 1 != 0 || header.encrypted & ~3 != 0 {
            throw MDictError.encrypted
        }

        let (keyBlockRanges, recordBlockCursor) = try Self.parseKeyBlockRanges(
            data, cursor: &cursor, header: header
        )
        self.keyBlockRanges = keyBlockRanges
        // Binary search is valid only for ordered boundaries. Equal adjacent boundaries are
        // legitimate when one headword spans blocks; a per-query work budget bounds overlap.
        var previousFirst = "", previousLast = ""
        for range in keyBlockRanges {
            let first = header.keyCaseSensitive ? range.firstKey : range.firstKey.lowercased()
            let last = header.keyCaseSensitive ? range.lastKey : range.lastKey.lowercased()
            guard first <= last, previousFirst <= first, previousLast <= last else {
                throw MDictError.invalidFormat("Unordered key block boundaries")
            }
            previousFirst = first; previousLast = last
        }
        cursor = recordBlockCursor

        let (infos, blocksStart) = try Self.parseRecordBlockInfo(
            data, cursor: &cursor, header: header
        )
        self.recordBlockRanges = try Self.buildRecordBlockRanges(
            infos,
            blocksStart: blocksStart
        )

        self.entryCount = keyBlockRanges.last?.entryEndIndex ?? 0
        guard recordBlockRanges.last.map({ $0.compressedStart + Int($0.info.compressedSize) <= data.count }) ?? true else {
            throw MDictError.invalidFormat("Record blocks exceed file bounds")
        }
    }

    // MARK: Internal

    let header: MDictHeader
    let keyBlockRanges: [MDictKeyBlockRange]
    let entryCount: Int

    let data: Data
    let recordBlockRanges: [RecordBlockRange]
    var keyBlockCache: [Int: [MDictKeyEntry]] = [:]
    var keyBlockCacheOrder: [Int] = []
    var decompressedBlockCache: [Int: Data] = [:]
    var decompressedBlockCacheOrder: [Int] = []
    var decompressedBlockCacheBytes = 0

    var totalDecompressedRecordSize: UInt64 {
        recordBlockRanges.last?.decompressedEnd ?? 0
    }

    static func buildRecordBlockRanges(
        _ infos: [RecordBlockInfo],
        blocksStart: Int
    ) throws
        -> [RecordBlockRange] {
        var compressedStart = blocksStart
        var decompressedStart: UInt64 = 0
        var ranges: [RecordBlockRange] = []
        ranges.reserveCapacity(infos.count)

        for info in infos {
            guard info.compressedSize <= UInt64(maxMDictDecompressedBlockSize + 1024 * 1024),
                  info.decompressedSize <= UInt64(maxMDictDecompressedBlockSize),
                  !compressedStart.addingReportingOverflow(Int(info.compressedSize)).overflow,
                  !decompressedStart.addingReportingOverflow(info.decompressedSize).overflow else {
                throw MDictError.invalidFormat("Record block range exceeds supported limits")
            }
            ranges.append(RecordBlockRange(
                info: info,
                compressedStart: compressedStart,
                decompressedStart: decompressedStart
            ))
            compressedStart += try checkedInt(
                info.compressedSize,
                context: "record block compressed size"
            )
            decompressedStart += info.decompressedSize
        }
        return ranges
    }

    /// Look up a text definition by word (MDX files).
    func lookup(_ word: String) throws -> String? {
        guard let data = try lookupData(for: word) else { return nil }
        return decodeTextRecord(data)
    }

    /// Look up all text definitions for a word (MDX files).
    func lookupAll(_ word: String) throws -> [String] {
        let records = try lookupAllData(for: word)
        return records.compactMap(decodeTextRecord)
    }

    /// Look up raw binary data by key (MDD files).
    func lookupData(for key: String) throws -> Data? {
        for entry in try matchingEntries(for: key) {
            let span = try recordSpan(for: entry)
            guard span.size > 0 else { continue }
            return try readRecord(at: span.offset, size: span.size)
        }
        return nil
    }

    /// Look up all raw binary records by key.
    func lookupAllData(for key: String) throws -> [Data] {
        var records: [Data] = []
        var seen = Set<RecordSpan>()
        var bytes = 0
        for entry in try matchingEntries(for: key) {
            let span = try recordSpan(for: entry)
            guard span.size > 0,
                  seen.insert(span).inserted
            else { continue }
            guard records.count < 16, span.size <= maxMDictResultBytes - bytes else {
                throw MDictError.invalidFormat("Too many or oversized matching records")
            }
            bytes += span.size
            records.append(try readRecord(at: span.offset, size: span.size))
        }
        return records
    }

    func decodeTextRecord(_ data: Data) -> String? {
        String(data: data, encoding: header.encoding)?
            .replacingOccurrences(of: "\0", with: "")
    }

    func recordSpan(for entry: MDictKeyEntry) throws -> RecordSpan {
        let nextOffset = try nextRecordOffset(after: entry)
        guard nextOffset >= entry.recordOffset, nextOffset <= totalDecompressedRecordSize,
              nextOffset - entry.recordOffset <= UInt64(maxMDictRecordSize) else {
            throw MDictError.invalidFormat("Record offsets are not sorted")
        }
        let recordSize = Int(nextOffset - entry.recordOffset)
        return RecordSpan(offset: entry.recordOffset, size: recordSize)
    }

    func normalizedKey(_ key: String) -> String {
        header.keyCaseSensitive ? key : key.lowercased()
    }
}
