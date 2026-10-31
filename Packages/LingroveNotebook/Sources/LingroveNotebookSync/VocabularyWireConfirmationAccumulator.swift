import CryptoKit
import Foundation

/// A verified compact result is intentionally not Codable or publicly
/// constructible. The complete page stream and frozen members were checked.
/// Conversion is for in-memory consumers until the host's staged persistence is
/// installed; large outcomes cannot round-trip through the old 10k Codable path.
/// Positive retirement still requires a covering canonical window; a negative
/// result preserves all journals and only resolves the old frozen identity.
public nonisolated struct VocabularyWireVerifiedConfirmation: Sendable {
    public let manifest: VocabularyWireConfirmationManifest
    public let batch: VocabularyWireUploadBatch
    public let outcome: VocabularyWireGroupOutcome
    fileprivate init(manifest: VocabularyWireConfirmationManifest, batch: VocabularyWireUploadBatch) {
        self.manifest = manifest; self.batch = batch
        let ids = batch.request.members.map(\.memberID)
        switch manifest.decision {
        case let .committed(sequence): outcome = .committed(.init(notebookID: batch.scope.notebookID, groupID: batch.request.groupID,
            committedSequence: sequence, verifiedMemberIDs: ids))
        case let .rejected(reason): outcome = .rejected(.init(notebookID: batch.scope.notebookID, groupID: batch.request.groupID,
            reason: reason, verifiedMemberIDs: ids))
        }
    }
}

/// Owned by one verification pass. A host resumes by replaying its durable
/// ordered page bytes into a new value, exactly as for read windows. Only hashes
/// and counts are accumulated: UUIDs are compared directly to the frozen request
/// instead of keeping a second million-entry verification collection.
public nonisolated struct VocabularyWireConfirmationAccumulator {
    public let manifest: VocabularyWireConfirmationManifest
    private let upload: VocabularyWireStagedUpload
    private var nextOrdinal = 0
    private var receivedMembers = 0
    private var pages = SHA256()
    private var members = SHA256()
    private var finished = false
    public init(manifest: VocabularyWireConfirmationManifest, expecting upload: VocabularyWireStagedUpload) throws {
        try manifest.validate(for: upload); self.manifest = manifest; self.upload = upload
        pages.update(data: Data("lingrove-corpus-confirmation-pages:1\n".utf8))
    }
    public mutating func accept(_ page: VocabularyWireConfirmationPage) throws -> Data {
        guard !finished, page.ordinal == nextOrdinal else { throw VocabularyWireStagedError.invalidPage }
        let checked = try page.verified(for: manifest, upload: upload)
        guard receivedMembers <= upload.batch.request.members.count,
              checked.members.count <= upload.batch.request.members.count - receivedMembers else { throw VocabularyWireStagedError.invalidPage }
        let expected = upload.batch.request.members[receivedMembers..<(receivedMembers + checked.members.count)]
        guard zip(expected, checked.members).allSatisfy({ $0.memberID == $1 }) else { throw VocabularyWireStagedError.invalidPage }
        pages.update(data: Data("\(page.ordinal):\(page.sha256):\(page.byteCount)\n".utf8)); members.update(data: checked.bytes)
        receivedMembers += checked.members.count; nextOrdinal += 1
        return checked.bytes
    }
    public mutating func finish() throws -> VocabularyWireVerifiedConfirmation {
        guard !finished else { throw VocabularyWireStagedError.incompleteConfirmation }; finished = true
        guard nextOrdinal == manifest.pageCount, receivedMembers == manifest.memberCount,
              members.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.memberIDsSHA256,
              pages.finalize().map({ String(format: "%02x", $0) }).joined() == manifest.pagesSHA256 else { throw VocabularyWireStagedError.incompleteConfirmation }
        return .init(manifest: manifest, batch: upload.batch)
    }
}
