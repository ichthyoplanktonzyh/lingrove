import Foundation

/// Optional host diagnostics. Storage owns recovery; the app owns logs and privacy choices.
public enum NotebookWorkspaceRead { case loadWorkspace, loadWorkspaceSchedulerSettings }

public enum NotebookStorageDiagnostic {
    case invalidSchedule(workspaceID: String, cardID: String, reason: String)
    case workspaceReadFailed(read: NotebookWorkspaceRead, sourceWorkspaceID: String, activeWorkspaceID: String?, workspaceCount: Int?, errorType: String?)
}
