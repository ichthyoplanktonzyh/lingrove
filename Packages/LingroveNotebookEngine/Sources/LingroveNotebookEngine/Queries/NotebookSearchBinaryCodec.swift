import Foundation
import LingroveNotebook

/// This private cache format removes keyed-decoder work from hundreds of thousands of field
/// references. It is rebuildable, local and versioned separately from corpus/backups/sync.
/// Each count and byte range is checked before allocation/read; no borrowed memory escapes
/// Data.withUnsafeBytes. A failed checksum/shape/format always requests canonical preparation.
enum NotebookSearchBinaryCodec {
    private static let magic: UInt32 = 0x3253474c // LGS2, little endian
    static func encode(_ value: NotebookSearchProjection) -> Data? {
        guard value.fence.corpus.schemaVersion >= 0, value.fence.corpus.value >= 0 else { return nil }
        var writer = Writer()
        writer.u32(magic)
        writer.string(value.fence.version.workspaceId); writer.uuid(value.fence.version.notebookId)
        writer.u64(value.fence.version.revision); writer.string(value.fence.version.generation)
        writer.u64(UInt64(value.fence.corpus.schemaVersion)); writer.string(value.fence.corpus.epoch)
        writer.u64(UInt64(value.fence.corpus.value))
        writer.count(value.texts.count); for text in value.texts { writer.string(text) }
        writer.count(value.headers.count)
        for entry in value.headers {
            writer.uuid(entry.id); writer.u64((value.dates[entry.id] ?? 0).bitPattern)
            writer.string(entry.expression); writer.string(entry.language?.rawValue ?? "")
            writer.count(entry.senses.count)
            for sense in entry.senses { writer.uuid(sense.id); writer.string(sense.title); writer.byte(sense.hasImage ? 1 : 0) }
        }
        writer.map(value.fields); writer.map(value.nodes)
        writer.count(value.mappings.count)
        for mapping in value.mappings { writer.uuid(mapping.sense); writer.uuid(mapping.node); writer.count(mapping.text) }
        writer.links(value.cues); writer.links(value.patterns)
        return writer.valid ? Data(writer.bytes) : nil
    }

    static func decode(_ data: Data) -> NotebookSearchProjection? {
        guard data.count <= NotebookSearchCache.maximumBytes else { return nil }
        return try? data.withUnsafeBytes { bytes in
            var reader = Reader(bytes: bytes)
            guard try reader.u32() == magic else { throw Invalid.cache }
            let workspace = try reader.string(), notebook = try reader.uuid(), revision = try reader.u64(), generation = try reader.string()
            let schema = try reader.u64(), epoch = try reader.string(), counter = try reader.u64()
            guard schema <= UInt64(Int.max), counter <= UInt64(Int64.max), revision <= UInt64(Int64.max) else { throw Invalid.cache }
            let fence = NotebookBrowseFence(version: .init(workspaceId: workspace, notebookId: notebook, revision: revision, generation: generation),
                corpus: .init(schemaVersion: Int(schema), epoch: epoch, value: Int64(counter)))
            let textCount = try reader.count(minimumBytes: 4)
            var texts: [String] = []; texts.reserveCapacity(textCount)
            for _ in 0..<textCount { texts.append(try reader.string()) }
            let entryCount = try reader.count(minimumBytes: 36)
            var headers: [NotebookEntrySummary] = [], dates: [UUID: Double] = [:]
            headers.reserveCapacity(entryCount); dates.reserveCapacity(entryCount)
            for _ in 0..<entryCount {
                let id = try reader.uuid(), date = try Double(bitPattern: reader.u64())
                let expression = try reader.string(), language = try reader.string()
                guard language.isEmpty || LearningLanguage(rawValue: language) != nil else { throw Invalid.cache }
                let count = try reader.count(minimumBytes: 21)
                var senses: [NotebookEntrySummary.Sense] = []; senses.reserveCapacity(count)
                for _ in 0..<count {
                    let id = try reader.uuid(), title = try reader.string(), image = try reader.byte()
                    guard image <= 1 else { throw Invalid.cache }
                    senses.append(.init(id: id, title: title, hasImage: image == 1))
                }
                dates[id] = date
                headers.append(.init(id: id, expression: expression, language: LearningLanguage(rawValue: language), senses: senses))
            }
            let fields = try reader.map(), nodes = try reader.map()
            let mappingCount = try reader.count(minimumBytes: 36)
            var mappings: [NotebookLiteralSearchMaterial.Mapping] = []; mappings.reserveCapacity(mappingCount)
            for _ in 0..<mappingCount { mappings.append(try .init(sense: reader.uuid(), node: reader.uuid(), text: Int(reader.u32()))) }
            let cues = try reader.links(), patterns = try reader.links()
            guard reader.offset == bytes.count else { throw Invalid.cache }
            return .init(fence: fence, texts: texts, headers: headers, dates: dates, fields: fields,
                nodes: nodes, mappings: mappings, cues: cues, patterns: patterns)
        }
    }

    private enum Invalid: Error { case cache }
    private struct Writer {
        var bytes: [UInt8] = []
        var valid = true
        mutating func allows(_ count: Int) -> Bool {
            valid = valid && count >= 0 && count <= NotebookSearchCache.maximumBytes - bytes.count
            return valid
        }
        init() { bytes.reserveCapacity(1_024 * 1_024) }
        mutating func u32(_ value: UInt32) {
            guard allows(MemoryLayout.size(ofValue: value)) else { return }
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        mutating func u64(_ value: UInt64) {
            guard allows(MemoryLayout.size(ofValue: value)) else { return }
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        mutating func count(_ value: Int) {
            guard let encoded = UInt32(exactly: value) else { valid = false; return }
            u32(encoded)
        }
        mutating func byte(_ value: UInt8) { if allows(1) { bytes.append(value) } }
        mutating func string(_ value: String) {
            count(value.utf8.count)
            if allows(value.utf8.count) { bytes.append(contentsOf: value.utf8) }
        }
        mutating func uuid(_ value: UUID) {
            guard allows(16) else { return }
            var value = value.uuid
            withUnsafeBytes(of: &value) { bytes.append(contentsOf: $0) }
        }
        mutating func map(_ values: [UUID: [Int]]) {
            count(values.count)
            for (id, refs) in values { uuid(id); count(refs.count); for ref in refs { count(ref) } }
        }
        mutating func links(_ values: [NotebookLiteralSearchMaterial.Link]) {
            count(values.count)
            for value in values { count(value.text); uuid(value.target) }
        }
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        var offset = 0
        mutating func span(_ count: Int) throws -> Int {
            guard count >= 0, count <= bytes.count - offset else { throw Invalid.cache }
            let start = offset; offset += count; return start
        }
        mutating func u32() throws -> UInt32 {
            let start = try span(4)
            return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: start, as: UInt32.self))
        }
        mutating func u64() throws -> UInt64 {
            let start = try span(8)
            return UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: start, as: UInt64.self))
        }
        mutating func byte() throws -> UInt8 { bytes[try span(1)] }
        mutating func count(minimumBytes: Int) throws -> Int {
            let value = Int(try u32())
            guard value <= 2_000_000, value <= (bytes.count - offset) / minimumBytes else { throw Invalid.cache }
            return value
        }
        mutating func string() throws -> String {
            let count = Int(try u32()), start = try span(count)
            return String(decoding: bytes.bindMemory(to: UInt8.self)[start..<start + count], as: UTF8.self)
        }
        mutating func uuid() throws -> UUID {
            let start = try span(16)
            return UUID(uuid: bytes.loadUnaligned(fromByteOffset: start, as: uuid_t.self))
        }
        mutating func map() throws -> [UUID: [Int]] {
            let count = try count(minimumBytes: 20)
            var result: [UUID: [Int]] = [:]; result.reserveCapacity(count)
            for _ in 0..<count {
                let id = try uuid(), refs = try self.count(minimumBytes: 4)
                guard result[id] == nil else { throw Invalid.cache }
                var values: [Int] = []; values.reserveCapacity(refs)
                for _ in 0..<refs { values.append(Int(try u32())) }
                result[id] = values
            }
            return result
        }
        mutating func links() throws -> [NotebookLiteralSearchMaterial.Link] {
            let count = try count(minimumBytes: 20)
            var result: [NotebookLiteralSearchMaterial.Link] = []; result.reserveCapacity(count)
            for _ in 0..<count { result.append(try .init(text: Int(u32()), target: uuid())) }
            return result
        }
    }
}
