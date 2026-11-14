import Foundation

/// The checked save state owns reference counts for corpus images. Entry edits update only
/// their old/new subtree; repeated note saves share the unchanged index. These counts enforce
/// the existing aggregate bound but grant no access to bytes: the engine still checks every
/// referenced asset's workspace ownership and registry metadata inside the transaction.
struct VocabularyMediaReferenceIndex: Sendable {
    private var byEntry: [UUID: Set<VocabularyImageReference>] = [:]
    private var counts: [VocabularyImageReference: Int] = [:]

    init(_ document: VocabularyDocument) {
        for entry in document.catalog {
            let refs = Self.references(entry)
            if !refs.isEmpty { byEntry[entry.id] = refs }
            for ref in refs { counts[ref, default: 0] += 1 }
        }

    }

    var references: Set<VocabularyImageReference> { Set(counts.keys) }

    func replacing(_ id: UUID, with entry: VocabularyEntry?) -> Self {
        let old = byEntry[id] ?? [], next = entry.map(Self.references) ?? []
        guard old != next else { return self }
        var result = self
        result.byEntry[id] = next.isEmpty ? nil : next
        for ref in old.subtracting(next) {
            if let count = result.counts[ref], count > 1 { result.counts[ref] = count - 1 }
            else { result.counts.removeValue(forKey: ref) }
        }
        for ref in next.subtracting(old) { result.counts[ref, default: 0] += 1 }
        return result
    }

    private static func references(_ entry: VocabularyEntry) -> Set<VocabularyImageReference> {
        let subtree = VocabularyDocument(catalog: [entry], sources: [], occurrences: [], interpretations: [])
        return Set(VocabularyDocumentValidation.imageReferences(subtree))
    }
}
