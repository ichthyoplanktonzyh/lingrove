import Foundation
import LingroveNotebook

/// One acknowledged corpus revision owns these derived, read-only lookup tables. The archive's
/// canonical values remain authoritative; the UI borrows this index instead of scanning every
/// entry for each row's menu, selection, tag or source reference.
nonisolated struct VocabularyReadIndex: Sendable {
    private(set) var entries: [VocabularyEntry]
    private(set) var entriesByID: [UUID: VocabularyEntry] = [:]
    private(set) var selectionsBySenseID: [UUID: VocabularySelection] = [:]
    private(set) var savedKeys: Set<String> = []
    private(set) var allTags: [String] = []
    private var entryIDsByKey: [String: UUID] = [:]
    private var tagCounts: [String: Int] = [:]

    init(entries: [VocabularyEntry] = []) {
        self.entries = entries
        for entry in entries {
            index(entry)
        }
        allTags = tagCounts.keys.sorted()
    }

    /// The caller checked the exact prior revision. Append and removal mirror the order of
    /// the canonical catalog and only recalculate keys and aliases owned by this entry.
    mutating func apply(_ change: VocabularyArchiveSnapshot.EntryChange) {
        if let offset = entries.firstIndex(where: { $0.id == change.entryID }) {
            unindex(entries[offset])
            if let entry = change.entry { entries[offset] = entry } else { entries.remove(at: offset) }
        } else if let entry = change.entry {
            entries.append(entry)
        }
        if let entry = change.entry { index(entry) }
        allTags = tagCounts.keys.sorted()
    }

    func entry(forKey key: String) -> VocabularyEntry? {
        entryIDsByKey[key].flatMap { entriesByID[$0] }
    }

    func entry(forSense id: UUID) -> VocabularyEntry? {
        selectionsBySenseID[id].flatMap { entriesByID[$0.entryID] }
    }

    private mutating func index(_ entry: VocabularyEntry) {
        entriesByID[entry.id] = entry
        let key = VocabularyPolicy.entryKey(entry)
        if !entry.senses.isEmpty { entryIDsByKey[key] = entry.id }
        for sense in entry.senses {
            let target = VocabularySelection(entryID: entry.id, senseID: sense.id)
            selectionsBySenseID[sense.id] = target
            for alias in sense.mergedFrom { selectionsBySenseID[alias] = target }
            for tag in sense.tags { tagCounts[tag, default: 0] += 1 }
            for example in sense.examples { savedKeys.insert(key + ":" + VocabularyPolicy.exampleKey(example)) }
        }
    }

    private mutating func unindex(_ entry: VocabularyEntry) {
        entriesByID.removeValue(forKey: entry.id)
        let key = VocabularyPolicy.entryKey(entry)
        entryIDsByKey.removeValue(forKey: key)
        for sense in entry.senses {
            selectionsBySenseID.removeValue(forKey: sense.id)
            for alias in sense.mergedFrom { selectionsBySenseID.removeValue(forKey: alias) }
            for tag in sense.tags {
                let count = (tagCounts[tag] ?? 1) - 1
                tagCounts[tag] = count == 0 ? nil : count
            }
            for example in sense.examples { savedKeys.remove(key + ":" + VocabularyPolicy.exampleKey(example)) }
        }
    }
}
