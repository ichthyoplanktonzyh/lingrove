import Foundation

/// The checked save state owns these reverse lookups. A replacement checks only its own IDs,
/// lifecycle fields and accepted occurrences against the unchanged proof, rather than rebuilding
/// global sets for every note/capture. Full reads/imports still establish that proof first.
struct VocabularyEntryValidationIndex: Sendable {
    private var keys: [String: UUID] = [:]
    private var owners: [UUID: UUID] = [:]
    private var acceptedOccurrences: [UUID: UUID] = [:]
    private var semanticIDs: Set<UUID>

    init(entries: [VocabularyEntry], identifiers: [UUID: Set<UUID>], semantics: VocabularySemanticIndex) {
        semanticIDs = VocabularySemanticPolicy.identifiers(semantics)
        for entry in entries { insert(entry, ids: identifiers[entry.id] ?? []) }
    }

    func validate(_ entry: VocabularyEntry, ids: Set<UUID>) throws {
        let key = VocabularyIdentityPolicy.entryKey(entry)
        guard keys[key].map({ $0 == entry.id }) ?? true,
              ids.allSatisfy({ owners[$0].map { $0 == entry.id } ?? true }),
              entry.senses.filter(\.isSavedWithoutContext).count <= 1 else { throw VocabularyError.invalidArchive }
        let lexical = Set([entry.id] + entry.senses.map(\.id) + entry.examples.map(\.id))
        guard lexical.isDisjoint(with: semanticIDs) else { throw VocabularyError.invalidArchive }
        var occurrences = Set<UUID>()
        for sense in entry.senses {
            guard sense.note.utf8.count <= 262_144, sense.tags.count <= 100,
                  sense.tags.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }),
                  sense.savedAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw VocabularyError.invalidArchive }
            for example in sense.examples {
                let occurrence = example.occurrenceID ?? example.id
                guard occurrences.insert(occurrence).inserted,
                      acceptedOccurrences[occurrence].map({ $0 == entry.id }) ?? true,
                      example.ranges.count <= 64, example.meaning.utf8.count <= 32_000,
                      example.translation.utf8.count <= 262_144, example.translationVariants.count <= 64,
                      (example.appBundleIdentifier?.utf8.count ?? 0) <= 1_024,
                      example.createdAt.timeIntervalSince1970.isFinite else { throw VocabularyError.invalidArchive }
            }
        }
    }

    func replacing(_ old: VocabularyEntry?, with entry: VocabularyEntry?, oldIDs: Set<UUID>, newIDs: Set<UUID>,
                   removedSemanticIDs: Set<UUID>) -> Self {
        var result = self
        let oldKey = old.map(VocabularyIdentityPolicy.entryKey), newKey = entry.map(VocabularyIdentityPolicy.entryKey)
        if oldKey != newKey {
            if let oldKey { result.keys.removeValue(forKey: oldKey) }
            if let newKey, let entry { result.keys[newKey] = entry.id }
        }
        for id in oldIDs.subtracting(newIDs) { result.owners.removeValue(forKey: id) }
        if let entry { for id in newIDs.subtracting(oldIDs) { result.owners[id] = entry.id } }
        let before = Set(old?.examples.map { $0.occurrenceID ?? $0.id } ?? [])
        let after = Set(entry?.examples.map { $0.occurrenceID ?? $0.id } ?? [])
        for id in before.subtracting(after) { result.acceptedOccurrences.removeValue(forKey: id) }
        if let entry { for id in after.subtracting(before) { result.acceptedOccurrences[id] = entry.id } }
        if !removedSemanticIDs.isEmpty { result.semanticIDs.subtract(removedSemanticIDs) }
        return result
    }

    func updatingSemanticIDs(removing: Set<UUID>, adding: Set<UUID>) -> Self {
        guard !removing.isEmpty || !adding.isEmpty else { return self }
        var result = self; result.semanticIDs.subtract(removing); result.semanticIDs.formUnion(adding); return result
    }

    mutating func insert(_ entry: VocabularyEntry, ids: Set<UUID>) {
        keys[VocabularyIdentityPolicy.entryKey(entry)] = entry.id
        for id in ids { owners[id] = entry.id }
        for example in entry.examples { acceptedOccurrences[example.occurrenceID ?? example.id] = entry.id }
    }
}
