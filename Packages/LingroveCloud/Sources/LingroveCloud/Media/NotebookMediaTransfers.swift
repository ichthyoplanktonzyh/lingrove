import Foundation

/// The process owns this tiny cancellation registry, not the UI or SQLite.
/// Its task covers one complete queue attempt; cancelling it reaches URLSession
/// even before response headers arrive. Durable revisions remain authoritative
/// because cancelling a task cannot undo bytes a remote server already stored.
@MainActor
public final class NotebookMediaTransfers {
    public init() {}
    private struct Active {
        let attemptID: String
        let task: Task<Void, Error>
    }
    private var active: [String: Active] = [:]

    func perform(_ job: NotebookMediaJob, operation: @escaping @MainActor () async throws -> Void) async throws {
        guard let attemptID = job.attemptID, active[job.id] == nil else { throw NotebookMediaError.busy }
        let task = Task { try await operation() }
        active[job.id] = Active(attemptID: attemptID, task: task)
        defer { if active[job.id]?.attemptID == attemptID { active.removeValue(forKey: job.id) } }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    public func cancel(_ jobID: String) { active[jobID]?.task.cancel() }
}
