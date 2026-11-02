import Foundation
import LingroveNotebook

/// Operational media stages borrow the host's durable queue and pin ledger. The host checks both
/// account generation and attempt revision/CAS inside each mutation, validates PNG/digest before
/// completion, and keeps a pin until the corpus apply has committed. HTTP never owns media files.
@MainActor
public protocol NotebookMediaStorage: AnyObject {
    func enqueue(_ references: [VocabularyImageReference], direction: NotebookMediaDirection,
                 consumer: String, binding: NotebookBinding) async throws -> [NotebookMediaJob]
    func claim(_ job: NotebookMediaJob, binding: NotebookBinding, recheckReady: Bool) async throws -> NotebookMediaJob
    func check(_ job: NotebookMediaJob, binding: NotebookBinding) async throws
    func complete(_ job: NotebookMediaJob, assetID: UUID?, received: Data?, binding: NotebookBinding) async throws
    func fail(_ job: NotebookMediaJob, state: NotebookMediaState, binding: NotebookBinding) async throws
    func available(_ job: NotebookMediaJob, binding: NotebookBinding) async throws
    func owned(_ reference: VocabularyImageReference, binding: NotebookBinding) async throws -> Data
    func release(consumer: String, binding: NotebookBinding) async throws
    func prune(binding: NotebookBinding) async throws -> [VocabularyImageReference]
    func acknowledgeRelease(_ reference: VocabularyImageReference, binding: NotebookBinding) async throws
}
