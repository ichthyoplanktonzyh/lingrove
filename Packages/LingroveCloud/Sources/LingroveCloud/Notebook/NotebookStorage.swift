import Foundation
import LingroveNotebook
import LingroveNotebookSync

/// The app-owned repository implements these stages using its one primary database. Async methods
/// borrow a connection only for the stage, never across HTTP awaits. Every write must validate the
/// supplied generation in its own transaction; `validate` also fences in-memory continuations.
/// Outcome recording retains exact frozen coverage; only verified window apply retires its ACK.
@MainActor
public protocol NotebookStorage: AnyObject {
    func installation(for account: NotebookAccount) throws -> UUID
    func capture(scope: VocabularyWireWindowScope) throws -> NotebookBinding
    func validate(_ binding: NotebookBinding) throws
    func initial(_ binding: NotebookBinding) async throws -> NotebookLocalState
    func state(_ binding: NotebookBinding) async throws -> NotebookLocalState
    func ownershipPending(_ binding: NotebookBinding) async throws -> Bool
    func sequence(_ binding: NotebookBinding) async throws -> VocabularyWireSequence?
    func hasConflict(_ binding: NotebookBinding) async throws -> Bool
    func next(_ binding: NotebookBinding, staged: VocabularyWireStagedCapabilities?) async throws -> NotebookPendingUpload?
    func control(_ pending: NotebookPendingUpload, binding: NotebookBinding) async throws -> NotebookUploadControl
    func existing(_ pending: NotebookPendingUpload, binding: NotebookBinding) async throws -> NotebookPendingUpload
    func record(_ outcome: VocabularyWireGroupOutcome, pending: NotebookPendingUpload, binding: NotebookBinding) async throws
    func record(_ manifest: VocabularyWireConfirmationManifest, pending: NotebookPendingUpload, binding: NotebookBinding) async throws
    func record(_ page: VocabularyWireConfirmationPage, manifest: VocabularyWireConfirmationManifest,
                pending: NotebookPendingUpload, binding: NotebookBinding) async throws
    func closeUpload(_ manifest: VocabularyWireStagedManifest, pending: NotebookPendingUpload, binding: NotebookBinding) async throws
    func authorize(_ authorization: NotebookRetryAuthorization) async throws
    func begin(_ manifest: VocabularyWireWindowManifest, binding: NotebookBinding) async throws -> [Int]
    func receive(_ page: VocabularyWireWindowPage, manifest: VocabularyWireWindowManifest, binding: NotebookBinding) async throws
    func discard(_ manifest: VocabularyWireWindowManifest, binding: NotebookBinding) async throws
    func windowReferences(_ manifest: VocabularyWireWindowManifest, images: [String: Data], binding: NotebookBinding) async throws -> [VocabularyImageReference]
    func apply(_ manifest: VocabularyWireWindowManifest, binding: NotebookBinding, images: [String: Data]) async throws
}

/// The frozen review wire envelope is produced by the repository's canonical codec and byte
/// admission. This package neither decodes Card/FSRS nor constructs a second review wire schema.
/// `hasWork` includes all held lanes, including history adoptions, not just card operations.
public nonisolated struct NotebookReviewRequest: Sendable {
    public static let maximumBytes = 7 * 1024 * 1024
    public let body: Data
    public let afterSequence: Int64
    public let hasWork: Bool
    public init(body: Data, afterSequence: Int64, hasWork: Bool) throws {
        guard !body.isEmpty, body.count <= Self.maximumBytes, afterSequence >= 0 else { throw NotebookNetworkError.invalidReply }
        self.body = body; self.afterSequence = afterSequence; self.hasWork = hasWork
    }
}

/// Review persistence owns decoding, source/clock checks and exact ACK in one transaction.
/// A thrown apply leaves the independent review cursor unchanged; corpus already committed.
@MainActor
public protocol NotebookReviewStorage: AnyObject {
    func revision(_ binding: NotebookBinding) async throws -> Int64
    func request(_ binding: NotebookBinding) async throws -> NotebookReviewRequest
    /// Return the validated response's hasMore, after checking response scope and exact sent IDs.
    func apply(_ response: Data, request: NotebookReviewRequest, binding: NotebookBinding) async throws -> Bool
}
