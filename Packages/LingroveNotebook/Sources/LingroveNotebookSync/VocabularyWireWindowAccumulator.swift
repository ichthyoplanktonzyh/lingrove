import CryptoKit
import Foundation

/// This proof has no public initializer or Codable conformance. Bytes, counts,
/// clocks and scope have been checked; whole-graph validation is still required
/// when applying its records to a confirmed server shadow.
public nonisolated struct VocabularyWireVerifiedWindow: Sendable {
    public let manifest: VocabularyWireWindowManifest
    public let records: [VocabularyWireCorpusRecord]
    fileprivate init(manifest: VocabularyWireWindowManifest, records: [VocabularyWireCorpusRecord]) { self.manifest = manifest; self.records = records }
}

/// Owned by a single verification operation, not a service/actor. A host can
/// reconstruct it by replaying its durable ordered pages after a restart. It
/// holds hashes/counters only, and returns each checked byte chunk to storage.
public nonisolated struct VocabularyWireWindowAccumulator {
    public let manifest: VocabularyWireWindowManifest
    private let scope: VocabularyWireWindowScope
    private var nextOrdinal = 0
    private var receivedBytes = 0
    private var descriptors = SHA256()
    private var contents = SHA256()
    private var finished = false
    public init(manifest: VocabularyWireWindowManifest, expecting scope: VocabularyWireWindowScope, now: Date) throws {
        try manifest.validate(expecting: scope, now: now); self.manifest = manifest; self.scope = scope
    }
    public mutating func accept(_ page: VocabularyWireWindowPage, now: Date) throws -> Data {
        guard !finished, page.ordinal == nextOrdinal else { throw VocabularyWireWindowError.invalidPage }
        let bytes = try page.verifiedBytes(for: manifest, expecting: scope, now: now)
        descriptors.update(data: Data("\(page.ordinal):\(page.sha256):\(page.byteCount)\n".utf8)); contents.update(data: bytes)
        nextOrdinal += 1; receivedBytes += bytes.count
        return bytes
    }
    public mutating func finish(recordsJSON: Data, now: Date) throws -> VocabularyWireVerifiedWindow {
        // Finalization is terminal even on a failure. A durable caller retries
        // by replaying its staged pages into a fresh verifier, never by relying
        // on a finalized cryptographic context being reusable.
        guard !finished else { throw VocabularyWireWindowError.incompleteWindow }
        finished = true
        try manifest.validate(expecting: scope, now: now)
        guard nextOrdinal == manifest.pageCount, receivedBytes == manifest.byteCount,
              descriptors.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.pagesSHA256,
              recordsJSON.count == receivedBytes, SHA256.hash(data: recordsJSON) == contents.finalize() else { throw VocabularyWireWindowError.incompleteWindow }
        let records: [VocabularyWireCorpusRecord]
        do { records = try JSONDecoder().decode([VocabularyWireCorpusRecord].self, from: recordsJSON) }
        catch { throw VocabularyWireWindowError.invalidRecord }
        guard records.count == manifest.recordCount else { throw VocabularyWireWindowError.invalidRecord }
        var identities = Set<String>()
        for record in records {
            guard identities.insert(record.key).inserted else { throw VocabularyWireWindowError.duplicateRecord }
            guard record.version <= manifest.highWaterSequence,
                  manifest.afterSequence.map({ record.version > $0 }) ?? true else { throw VocabularyWireWindowError.invalidRecord }
            if record.entity.entityType == .notebookSettings, record.entity.entityID != manifest.scope.notebookID.uuidString.lowercased() {
                throw VocabularyWireWindowError.invalidRecord
            }
        }
        if !manifest.initialized {
            guard records.isEmpty, recordsJSON == Data("[]".utf8) else { throw VocabularyWireWindowError.invalidRecord }
        }
        return .init(manifest: manifest, records: records)
    }
}
