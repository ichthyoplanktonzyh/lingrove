import Foundation
import LingroveNotebook
import Testing
@testable import Lingrove

/// Compare incremental outputs with complete policy builds and check the actual invalidation
/// set. These synthetic values need neither a database nor an embedding model.
@MainActor
struct VocabularySearchPreparationTests {
    @Test func unassociatedInsertAndRemovalKeepExistingRetrievalDocuments() throws {
        let fixture = VocabularySearchPolicyTests.influenceFixture()
        var entries = fixture.entries, preparation = VocabularySearchPreparation()
        let first = UUID()
        let before = preparation.prepare(entries: entries, semantics: fixture.semantics, revision: first)
        let now = Date()
        let added = VocabularyEntry(id: UUID(), expression: "new word", dictionaryForm: "new word", language: .english, kind: .word,
            senses: [.init(id: UUID(), meaning: "A new unassociated meaning", createdAt: now, updatedAt: now)],
            createdAt: now, updatedAt: now)
        entries.append(added)
        let second = UUID()
        let inserted = preparation.prepare(entries: entries, semantics: fixture.semantics, revision: second,
            entryChange: .init(baseRevision: first, revision: second, entryID: added.id))
        #expect(inserted.rebuiltSenses == [added.senses[0].id] && inserted.rebuiltMeanings.isEmpty)
        #expect(inserted.meanings.map(\.fingerprint) == before.meanings.map(\.fingerprint))
        try sameAsFull(inserted, entries: entries, semantics: fixture.semantics)
        entries.removeLast()
        let third = UUID()
        let removed = preparation.prepare(entries: entries, semantics: fixture.semantics, revision: third,
            entryChange: .init(baseRevision: second, revision: third, entryID: added.id))
        #expect(removed.rebuiltSenses.isEmpty && removed.rebuiltMeanings.isEmpty)
        try sameAsFull(removed, entries: entries, semantics: fixture.semantics)
    }

    @Test func anAnnotationSaveKeepsBoundedExampleRetrievalMaterialStable() throws {
        var entry = try #require(VocabularySearchPolicyTests.influenceFixture().entries.first)
        let now = Date(timeIntervalSince1970: 100)
        entry.senses[0].examples = (0..<12).map { index in
            VocabularyExample(id: UUID(), text: "Example \(index).", translation: "", ranges: [],
                completeness: .sentence, meaning: "Distinct adopted definition \(index)", createdAt: now.addingTimeInterval(Double(index)))
        }
        let state = try VocabularyEntrySaveState(validating: .init(entries: [entry]))
        var preparation = VocabularySearchPreparation()
        let revision = UUID()
        let before = preparation.prepare(entries: state.entries, semantics: .init(), revision: revision)
        var edited = state.entries[0]; edited.senses[0].note = "Only a personal annotation"
        let saved = try state.replacing(edited)
        let next = UUID()
        let after = preparation.prepare(entries: saved.state.entries, semantics: .init(), revision: next,
            entryChange: .init(baseRevision: revision, revision: next, entryID: entry.id))
        #expect(after.embeddingRevision == before.embeddingRevision)
        #expect(after.rebuiltSenses.isEmpty && after.documents == before.documents)
    }

    @Test func consecutiveReceiptsReuseMeaningsAndGapsFallBackToTheCompleteSnapshot() throws {
        let fixture = VocabularySearchPolicyTests.influenceFixture()
        var entries = fixture.entries, preparation = VocabularySearchPreparation()
        let firstRevision = UUID(), secondRevision = UUID()
        _ = preparation.prepare(entries: entries, semantics: fixture.semantics, revision: firstRevision)
        entries[0].senses[0].meaning = "An acknowledged single-sense edit"
        let fast = preparation.prepare(entries: entries, semantics: fixture.semantics, revision: secondRevision,
            entryChange: .init(baseRevision: firstRevision, revision: secondRevision, entryID: entries[0].id))
        #expect(fast.rebuiltSenses == [entries[0].senses[0].id] && fast.rebuiltMeanings.isEmpty)
        try sameAsFull(fast, entries: entries, semantics: fixture.semantics)
        // Debounce can skip several receipts. The latest delta cannot hide another entry edit.
        entries[1].senses[0].meaning = "An intermediate edit"
        entries[2].senses[0].meaning = "The most recent edit"
        let latest = UUID()
        let fallback = preparation.prepare(entries: entries, semantics: fixture.semantics, revision: latest,
            entryChange: .init(baseRevision: UUID(), revision: latest, entryID: entries[2].id))
        #expect(fallback.rebuiltSenses == [entries[1].senses[0].id, entries[2].senses[0].id])
        try sameAsFull(fallback, entries: entries, semantics: fixture.semantics)
    }

    @Test func localEditsAndSemanticFanoutOnlyRebuildTheirRetrievalInputs() throws {
        let fixture = VocabularySearchPolicyTests.influenceFixture()
        var entries = fixture.entries, semantics = fixture.semantics
        var preparation = VocabularySearchPreparation()
        let cold = preparation.prepare(entries: entries, semantics: semantics)
        #expect(cold.rebuiltSenses == Set(entries.flatMap { $0.senses.map(\.id) }))
        let repeated = preparation.prepare(entries: entries, semantics: semantics)
        #expect(repeated.rebuiltSenses.isEmpty && repeated.rebuiltMeanings.isEmpty)
        #expect(repeated.embeddingRevision == cold.embeddingRevision)
        entries[0].senses[0].meaning = "A corrected adopted definition"
        let edited = preparation.prepare(entries: entries, semantics: semantics)
        #expect(edited.rebuiltSenses == [entries[0].senses[0].id] && edited.rebuiltMeanings.isEmpty)
        try sameAsFull(edited, entries: entries, semantics: semantics)
        semantics.nodes[0].definition += " A changed shared meaning."
        let shared = preparation.prepare(entries: entries, semantics: semantics)
        #expect(shared.rebuiltSenses == Set(entries.flatMap { $0.senses.map(\.id) }))
        #expect(shared.rebuiltMeanings == [semantics.nodes[0].id])
        try sameAsFull(shared, entries: entries, semantics: semantics)
    }

    @Test func notesSourceSentencesAndNodeMetadataRetainEmbeddingInputs() throws {
        let fixture = VocabularySearchPolicyTests.influenceFixture()
        var entries = fixture.entries, semantics = fixture.semantics
        var preparation = VocabularySearchPreparation()
        let cold = preparation.prepare(entries: entries, semantics: semantics)
        entries[0].senses[0].note = "A personal note"
        entries[0].updatedAt = Date().addingTimeInterval(120)
        semantics.nodes[0].scopeNote = "Authored display metadata"
        let edited = preparation.prepare(entries: entries, semantics: semantics)
        #expect(edited.rebuiltSenses.isEmpty && edited.rebuiltMeanings.isEmpty)
        #expect(edited.embeddingRevision == cold.embeddingRevision)
        #expect(edited.meanings.first?.node.scopeNote == "Authored display metadata")
        entries[0].senses[0].tags = ["new filter"]
        let tagged = preparation.prepare(entries: entries, semantics: semantics)
        #expect(tagged.rebuiltSenses == [entries[0].senses[0].id])
        #expect(tagged.embeddingRevision == cold.embeddingRevision)
        try sameAsFull(tagged, entries: entries, semantics: semantics)
    }

    @Test func cuesAdoptionMembershipDeletionAndSkippedSnapshotsMatchCompleteBuilds() throws {
        let fixture = VocabularySearchPolicyTests.influenceFixture()
        var entries = fixture.entries, semantics = fixture.semantics
        var preparation = VocabularySearchPreparation()
        _ = preparation.prepare(entries: entries, semantics: semantics)
        let cue = VocabularyRetrievalCue(id: UUID(), text: "change a result")
        semantics.cues = [cue]
        semantics.cueTargets = [.init(cueID: cue.id, nodeID: semantics.nodes[0].id)]
        var output = preparation.prepare(entries: entries, semantics: semantics)
        #expect(output.rebuiltMeanings == [semantics.nodes[0].id])
        try sameAsFull(output, entries: entries, semantics: semantics)
        semantics.mappings[0].provenance.status = .proposed
        entries.removeLast()
        output = preparation.prepare(entries: entries, semantics: semantics)
        try sameAsFull(output, entries: entries, semantics: semantics)
        semantics.nodes[0].provenance.status = .proposed
        output = preparation.prepare(entries: entries, semantics: semantics)
        #expect(output.meanings.isEmpty)
        try sameAsFull(output, entries: entries, semantics: semantics)
        entries = Array(entries.dropFirst())
        semantics = .init()
        output = preparation.prepare(entries: entries, semantics: semantics)
        try sameAsFull(output, entries: entries, semantics: semantics)
    }

    @Test func canonicalEquivalentAuthoredTextStillUpdatesLiteralDocuments() throws {
        let fixture = VocabularySearchPolicyTests.influenceFixture()
        var entries = fixture.entries
        entries[0].senses[0].meaning = "caf\u{00e9}"
        var preparation = VocabularySearchPreparation()
        let before = preparation.prepare(entries: entries, semantics: .init())
        entries[0].senses[0].meaning = "cafe\u{0301}"
        let after = preparation.prepare(entries: entries, semantics: .init())
        #expect(after.rebuiltSenses == [entries[0].senses[0].id])
        #expect(before.documents[0].fingerprint != after.documents[0].fingerprint)
        #expect(after.documents[0].meaning.utf8.elementsEqual(entries[0].senses[0].displayTitle.utf8))
        try sameAsFull(after, entries: entries, semantics: .init())
    }

    private func sameAsFull(_ snapshot: VocabularySearchPreparation.Snapshot, entries: [VocabularyEntry],
                            semantics: VocabularySemanticIndex) throws {
        #expect(snapshot.documents == VocabularySearchPolicy.documents(entries: entries, semantics: semantics))
        let full = VocabularySearchPolicy.meaningDocuments(entries: entries, semantics: semantics)
        #expect(snapshot.meanings.map(\.id) == full.map(\.id))
        for (actual, expected) in zip(snapshot.meanings, full) {
            #expect(actual.node == expected.node && actual.senseIDs == expected.senseIDs)
            #expect(actual.lookupTerms == expected.lookupTerms && actual.normalizedTerms == expected.normalizedTerms)
            #expect(actual.text.utf8.elementsEqual(expected.text.utf8) && actual.fingerprint == expected.fingerprint)
        }
    }
}
