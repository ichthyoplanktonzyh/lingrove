import Foundation
import LingroveNotebook

/// One acknowledged corpus revision owns these derived, read-only lookup tables. The archive's
/// canonical values remain authoritative; the UI borrows this index instead of scanning every
/// entry for each row's menu, selection, tag or source reference.
nonisolated struct VocabularyReadIndex: Sendable {
    let entries: [VocabularyEntry]
    let entriesByID: [UUID: VocabularyEntry]
    let selectionsBySenseID: [UUID: VocabularySelection]
    let allTags: [String]
    let entryKeys: Set<String>
    let savedKeys: Set<String>

    init(entries: [VocabularyEntry] = []) {
        self.entries = entries
        entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var selections: [UUID: VocabularySelection] = [:]
        var tags = Set<String>(), keys = Set<String>(), uses = Set<String>()
        for entry in entries {
            let key = VocabularyPolicy.entryKey(entry)
            if !entry.senses.isEmpty { keys.insert(key) }
            for sense in entry.senses {
                let target = VocabularySelection(entryID: entry.id, senseID: sense.id)
                selections[sense.id] = target
                for alias in sense.mergedFrom { selections[alias] = target }
                tags.formUnion(sense.tags)
                for example in sense.examples { uses.insert(key + ":" + VocabularyPolicy.exampleKey(example)) }
            }
        }
        selectionsBySenseID = selections; allTags = tags.sorted(); entryKeys = keys; savedKeys = uses
    }

    func entry(forSense id: UUID) -> VocabularyEntry? {
        selectionsBySenseID[id].flatMap { entriesByID[$0.entryID] }
    }
}
