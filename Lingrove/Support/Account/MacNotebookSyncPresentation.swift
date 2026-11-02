import Foundation
import LingroveNotebookSync

/// Pure settings copy maps independent lifecycle states without exposing backend diagnostics,
/// URLs, credentials or corpus text. The native sync controller owns behavior; this owns wording.
nonisolated enum MacNotebookSyncPresentation {
    /// Conflict choices show saved language material rather than transport UUIDs or raw JSON.
    /// Only known human text fields are projected, and the bounded preview never changes which
    /// exact entity snapshot the shared ownership command will validate at commit time.
    static func preview(_ entity: VocabularyWireEntity?) -> String? {
        guard let entity else { return nil }
        let fields = ["expression", "dictionaryForm", "meaning", "note", "text", "referenceText", "translatedText",
                      "definition", "prompt", "answer", "frontText", "backText", "name", "label", "title"]
        let text = fields.compactMap { key -> String? in
            guard case .string(let value)? = entity.fields[key], !value.isEmpty else { return nil }
            return value
        }.joined(separator: "\n")
        return text.isEmpty ? nil : String(text.prefix(600))
    }

    // This exhaustive table contains wording only; splitting it into helpers would hide missing
    // states without reducing behavioral complexity in the controller.
    // swiftlint:disable:next cyclomatic_complexity
    static func title(_ status: MacNotebookSyncStatus) -> String {
        switch status {
        case .local: String(localized: "Local only", table: "NotebookSync")
        case .needsWorkspace: String(localized: "Choose workspace", table: "NotebookSync")
        case .needsOwnership: String(localized: "Choose local ownership", table: "NotebookSync")
        case .ready: String(localized: "Ready", table: "NotebookSync")
        case .working: String(localized: "Working…", table: "NotebookSync")
        case .synchronized: String(localized: "Synced", table: "NotebookSync")
        case .pending: String(localized: "Pending", table: "NotebookSync")
        case .offline: String(localized: "Offline — retry when connected", table: "NotebookSync")
        case .unavailable: String(localized: "Service unavailable", table: "NotebookSync")
        case .forbidden: String(localized: "Access unavailable", table: "NotebookSync")
        case .failed: String(localized: "Failed — retry", table: "NotebookSync")
        case .conflict: String(localized: "Conflict — review required", table: "NotebookSync")
        case .rejected: String(localized: "Rejected — review required", table: "NotebookSync")
        case .cancelled: String(localized: "Cancelled", table: "NotebookSync")
        }
    }
}
