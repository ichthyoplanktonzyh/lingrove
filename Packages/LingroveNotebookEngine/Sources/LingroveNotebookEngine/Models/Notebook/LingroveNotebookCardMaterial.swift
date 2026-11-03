import CryptoKit
import Foundation
import LingroveNotebook

/// Pure source projection is shared by creation, explicit refresh and source navigation. It
/// consumes only a saved snapshot, never invokes an explanation model, and never reads Anki
/// configuration. SQLite admission remains the link store's responsibility at commit time.
extension LingroveNotebookCardMaterial {
    public static func draft(
        snapshot: LingroveNotebookSnapshot, selection: VocabularySelection, exampleId: UUID? = nil,
        intentId: UUID = UUID(), materialPlan: ReviewMaterialPlan? = nil
    ) throws -> LingroveNotebookCardDraft {
        let source = LingroveNotebookCardSource(workspaceId: snapshot.workspaceId, notebookId: snapshot.notebookId,
            entryId: selection.entryID, senseId: selection.senseID, exampleId: materialPlan == nil ? exampleId : materialPlan?.exampleID)
        guard let material = resolve(source: source, snapshot: snapshot, materialPlan: materialPlan), material.selection == selection else {
            throw VocabularyError.editConflict
        }
        return .init(id: intentId, source: source, sourceRevision: snapshot.revision, generatedContent: material.content, materialPlan: materialPlan)
    }

    public static func resolve(source: LingroveNotebookCardSource, snapshot: LingroveNotebookSnapshot, materialPlan: ReviewMaterialPlan? = nil) -> Self? {
        guard source.workspaceId == snapshot.workspaceId, source.notebookId == snapshot.notebookId else { return nil }
        for entry in snapshot.document.entries {
            for sense in entry.senses {
                guard sense.id == source.senseId || sense.mergedFrom.contains(source.senseId) else { continue }
                if let materialPlan {
                    guard materialPlan.exampleID == source.exampleId,
                          let content = try? render(entry: entry, sense: sense, plan: materialPlan, workspaceID: source.workspaceId) else { return nil }
                    return .init(selection: .init(entryID: entry.id, senseID: sense.id), exampleId: materialPlan.exampleID, content: content)
                }
                let example: VocabularyExample?
                if let id = source.exampleId {
                    guard let found = sense.examples.first(where: { $0.id == id }) else { return nil }
                    example = found
                } else {
                    example = nil
                }
                let front = example?.text ?? entry.expression
                let answer = example.map { [entry.expression, $0.translation, $0.meaning.isEmpty ? sense.meaning : $0.meaning] }
                    ?? [sense.meaning]
                var seen = Set<String>()
                let back = answer.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted }
                    .map(plainMarkdown).joined(separator: "\n\n")
                return .init(selection: .init(entryID: entry.id, senseID: sense.id), exampleId: example?.id,
                    content: normalized(.init(frontText: plainMarkdown(front), backText: back, tags: sense.tags)))
            }
        }
        return nil
    }

    /// Source navigation and enrollment resolution depend on the sense alone. Losing a chosen
    /// example must not hide the sense itself or make enrollment follow that example elsewhere.
    public static func resolvedSelection(
        source: LingroveNotebookCardSource, snapshot: LingroveNotebookSnapshot
    ) -> VocabularySelection? {
        guard source.workspaceId == snapshot.workspaceId, source.notebookId == snapshot.notebookId else { return nil }
        for entry in snapshot.document.entries {
            if let sense = entry.senses.first(where: { $0.id == source.senseId || $0.mergedFrom.contains(source.senseId) }) {
                return .init(entryID: entry.id, senseID: sense.id)
            }
        }
        return nil
    }

    /// Three-way refresh follows fields that still equal the prior generated value. A different
    /// field belongs to the Card editor and survives; tags follow the same ownership rule.
    /// Compare literal bytes: Swift String equality folds NFC/NFD, but an authored spelling is
    /// still a manual edit even when it is canonically equivalent to generated material.
    public static func refreshed(
        current: CardEditorInput, previous: CardEditorInput?, latest: CardEditorInput,
        replacingManualContent: Bool = false
    ) -> CardEditorInput {
        guard !replacingManualContent else { return latest }
        guard let previous else { return current }
        return .init(frontText: current.frontText.utf8.elementsEqual(previous.frontText.utf8) ? latest.frontText : current.frontText,
            backText: current.backText.utf8.elementsEqual(previous.backText.utf8) ? latest.backText : current.backText,
            tags: current.tags.elementsEqual(previous.tags, by: { $0.utf8.elementsEqual($1.utf8) }) ? latest.tags : current.tags)
    }

    public static func normalized(_ input: CardEditorInput) -> CardEditorInput {
        .init(frontText: input.frontText.trimmingCharacters(in: .whitespacesAndNewlines),
            backText: input.backText.trimmingCharacters(in: .whitespacesAndNewlines), tags: input.tags)
    }

    /// Generated baselines and their Card write gate must use the same literal ownership rule.
    /// Advancing an NFD baseline while skipping its canonically equivalent Card write would make
    /// that still-generated field look manually edited on the next refresh.
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
    /// participation/exercise. Deliberate additional exercises keep random creation intents.
    public static func stableID(_ purpose: String, workspace: String, sense: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("lingrove.review.v1|" + purpose + "|" + workspace.lowercased() + "|" + sense.uuidString.lowercased()).utf8)))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
        let a = Array(hex)
        let value = String(a[0..<8]) + "-" + String(a[8..<12]) + "-" + String(a[12..<16]) + "-" + String(a[16..<20]) + "-" + String(a[20..<32])
        return UUID(uuidString: value)!
    }

    static func plainMarkdown(_ text: String) -> String {
        // Notebook fields are plain text; copying their Markdown punctuation verbatim could turn
        // source evidence into a remote image or HTML instead of showing the captured wording.
        // Brackets and dollars use character references: their backslash escapes are ALSO
        // delimiters in the renderer's math extension. References keep those glyphs literal in
        // both native plain and Markdown paths without creating media or formulas.
        let references: [Character: String] = ["&": "&amp;", "[": "&#91;", "]": "&#93;", "$": "&#36;"]
        let escaped = Set("\\`*_{}<>#+-.!|~")
        return text.reduce(into: "") { result, character in
            if let reference = references[character] { result.append(reference); return }
            if escaped.contains(character) { result.append("\\") }
            result.append(character)
        }
    }
}
