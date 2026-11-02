import Foundation
import LingroveCloud
import LingroveNotebook
import LingroveNotebookEngine

extension NotebookEngineStorage {
    public func enqueue(_ references: [VocabularyImageReference], direction: NotebookMediaDirection,
                        consumer: String, binding: NotebookBinding) async throws -> [NotebookMediaJob] {
        try await stage(binding) { db in
            try LingroveNotebookMediaQueueStore(core: db.core).enqueue(references, direction: direction.engineDirection,
                consumer: consumer, binding: binding.engineBinding).map(\.networkJob)
        }
    }

    public func claim(_ job: NotebookMediaJob, binding: NotebookBinding, recheckReady: Bool) async throws -> NotebookMediaJob {
        try await stage(binding) { db in
            try LingroveNotebookMediaQueueStore(core: db.core).claim(job.id,
                binding: binding.engineBinding, recheckReady: recheckReady).networkJob
        }
    }

    public func check(_ job: NotebookMediaJob, binding: NotebookBinding) async throws {
        try await stage(binding) { db in try db.core.inReadTransaction {
            try LingroveNotebookMediaQueueStore(core: db.core).checkAttempt(job.engineJob, binding: binding.engineBinding)
        } }
    }

    public func complete(_ job: NotebookMediaJob, assetID: UUID?, received: Data?, binding: NotebookBinding) async throws {
        try await stage(binding) { db in
            try LingroveNotebookMediaQueueStore(core: db.core).complete(job.engineJob, remoteAssetID: assetID,
                binding: binding.engineBinding, received: received.map { (job.reference, $0) })
        }
    }

    public func fail(_ job: NotebookMediaJob, state: NotebookMediaState, binding: NotebookBinding) async throws {
        try await stage(binding) { db in
            try LingroveNotebookMediaQueueStore(core: db.core).fail(job.engineJob, state: state.engineState, binding: binding.engineBinding)
        }
    }

    public func available(_ job: NotebookMediaJob, binding: NotebookBinding) async throws {
        try await stage(binding) { db in
            try LingroveNotebookMediaQueueStore(core: db.core).available(job.engineJob, binding: binding.engineBinding)
        }
    }

    public func owned(_ reference: VocabularyImageReference, binding: NotebookBinding) async throws -> Data {
        try await stage(binding) { db in try db.core.inReadTransaction {
            try db.lingroveNotebookWindowStore.checkBindingInTransaction(binding.engineBinding)
            return try LingroveNotebookMediaStore(core: db.core).ownedImage(reference, workspaceId: binding.workspace)
        } }
    }

    public func release(consumer: String, binding: NotebookBinding) async throws {
        try await stage(binding) {
            try LingroveNotebookMediaQueueStore(core: $0.core).release(consumer: consumer, binding: binding.engineBinding)
        }
    }

    public func prune(binding: NotebookBinding) async throws -> [VocabularyImageReference] {
        try await stage(binding) { try LingroveNotebookMediaQueueStore(core: $0.core).prune(binding: binding.engineBinding) }
    }

    public func acknowledgeRelease(_ reference: VocabularyImageReference, binding: NotebookBinding) async throws {
        try await stage(binding) {
            try LingroveNotebookMediaQueueStore(core: $0.core).acknowledgeRelease(reference, binding: binding.engineBinding)
        }
    }
}
