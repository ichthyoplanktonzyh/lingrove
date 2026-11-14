import CryptoKit
import Foundation
import LingroveNotebook

/// Note persistence and source navigation share deterministic identities and historical sense
/// resolution here. This helper has no authoring, renderer, transport or database ownership.
extension LingroveNotebookCardMaterial {
    /// Source navigation and enrollment resolution depend on the sense alone. Losing a chosen
    /// example must not hide the sense itself or make enrollment follow that example elsewhere.
    public static func resolvedSelection(
        source: LingroveNotebookCardSource, snapshot: LingroveNotebookSnapshot
    ) -> VocabularySelection? {
        guard source.workspaceId == snapshot.workspaceId, source.notebookId == snapshot.notebookId else { return nil }
        // Only live and historical IDs matter here. Joining examples would rebuild the
        // entire corpus before every lookup.
        for entry in snapshot.document.catalog {
            if let sense = entry.senses.first(where: { $0.id == source.senseId || $0.mergedFrom.contains(source.senseId) }) {
                return .init(entryID: entry.id, senseID: sense.id)
            }
        }
        return nil
    }

    /// A Card projection and its baseline must advance using the same byte comparison. Swift
    /// String equality folds NFC/NFD, but persisted question text must still match its baseline.
    static func sameStoredBytes(_ lhs: CardEditorInput?, _ rhs: CardEditorInput?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (.some(a), .some(b)):
            return a.frontText.utf8.elementsEqual(b.frontText.utf8)
                && a.backText.utf8.elementsEqual(b.backText.utf8)
                && a.tags.elementsEqual(b.tags, by: { $0.utf8.elementsEqual($1.utf8) })
        default: return false
        }
    }

    /// Hash sorted JSON of values, not Swift's per-process randomized Hasher. This identifies an
    /// exact creation request across retries; it is neither a remote version nor a credential.
    public static func fingerprint<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    /// The same saved sense selected offline on two installations names the same default
    /// Note and template membership. A display-name change does not manufacture another Card.
    public static func stableID(_ purpose: String, workspace: String, sense: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("lingrove.review.v1|" + purpose + "|" + workspace.lowercased() + "|" + sense.uuidString.lowercased()).utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
        let a = Array(hex)
        let value = String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-" + String(a[16..<20]) + "-" + String(a[20..<32])
        return UUID(uuidString: value)!
    }

}
