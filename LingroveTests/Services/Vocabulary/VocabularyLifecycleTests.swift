import LingroveNotebook
import Foundation
import Testing
@testable import Lingrove

/// Private archives prove that evidence and uncertain claims survive without a notebook card
/// or meaning graph. No fixture reads or changes the developer's installed notebook.
@Suite(.serialized)
struct VocabularyLifecycleTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func material() -> VocabularyDocument {
        let source = VocabularySourceSnapshot(id: UUID(), text: "The bank is closed.", kind: .imported,
            appBundleIdentifier: nil, encounteredAt: now)
        let occurrence = VocabularySourceOccurrence(id: UUID(), sourceID: source.id,
            ranges: [.init(NSRange(location: 4, length: 4))])
        return .init(catalog: [], sources: [source], occurrences: [occurrence], interpretations: [])
    }

    @Test func sourceAndUnresolvedCandidatesRoundTripWithoutLexicalOrCollectionOwnership() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("library.sqlite"), archive = VocabularyArchive(url: url)
        var document = material()
        _ = try await archive.commit(document)
        #expect(try await VocabularyArchive(url: url).load().document == document)
        document.interpretations = [
            .init(id: UUID(), occurrenceID: document.occurrences[0].id, meaning: "银行", createdAt: now),
            .init(id: UUID(), occurrenceID: document.occurrences[0].id, meaning: "河岸", createdAt: now)
        ]
        let snapshot = try await archive.commit(document)
        #expect(snapshot.document.entries.isEmpty)
        #expect(try await VocabularyArchive(url: url).load().document == document)
        let backup = folder.appendingPathComponent("backup.lingrove")
        try await archive.backup(to: backup)
        #expect(try await VocabularyArchive(url: folder.appendingPathComponent("restore.sqlite")).restore(from: backup).document == document)
    }

    @Test func deletingAnExampleKeepsTheSenseAndRetiresItsEvidenceLink() async throws {
        let archive = VocabularyArchive(url: nil)
        var document = material()
        let senseID = UUID(), entryID = UUID()
        document.catalog = [.init(id: entryID, expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            senses: [.init(id: senseID, meaning: "银行", createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)]
        let claim = VocabularyInterpretation(id: UUID(), occurrenceID: document.occurrences[0].id, senseID: senseID,
            status: .accepted, meaning: "银行", createdAt: now)
        document.interpretations = [claim, .init(id: UUID(), occurrenceID: claim.occurrenceID, meaning: "河岸", createdAt: now)]
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "金融机构")])
        document.semantics.nodes = [node]
        document.semantics.mappings = [.init(nodeID: node.id, senseID: senseID, evidenceIDs: [claim.id])]
        let saved = try await archive.commit(document)
        let example = try #require(saved.document.entries.first?.examples.first)
        let removed = try await archive.remove(.init(expression: "bank", dictionaryForm: "bank", language: .english,
            kind: .word, example: example, senseID: senseID))
        #expect(removed.document.entries[0].senses[0].id == senseID)
        #expect(removed.document.entries[0].examples.isEmpty)
        #expect(!removed.document.interpretations.contains { $0.id == claim.id })
        #expect(removed.document.sources == document.sources && removed.document.occurrences == document.occurrences)
        #expect(removed.document.semantics.mappings.first?.evidenceIDs.isEmpty == true)
        #expect(try await archive.remove(id: entryID).document.entries.isEmpty)
        #expect(try await archive.load().document.catalog.isEmpty)
    }

    @Test func invalidClaimsAndCaptureDestinationsAreRejectedBeforeCommit() async throws {
        let archive = VocabularyArchive(url: nil)
        let original = material()
        _ = try await archive.commit(original)
        var invalid = original
        invalid.interpretations = [.init(id: UUID(), occurrenceID: UUID(), createdAt: now)]
        await #expect(throws: VocabularyError.self) { _ = try await archive.commit(invalid) }
        invalid = original
        invalid.interpretations = [.init(id: UUID(), occurrenceID: original.occurrences[0].id, status: .accepted, createdAt: now)]
        await #expect(throws: VocabularyError.self) { _ = try await archive.commit(invalid) }
        invalid = original
        invalid.interpretations = [.init(id: UUID(), occurrenceID: original.occurrences[0].id, senseID: UUID(), status: .accepted, createdAt: now)]
        await #expect(throws: VocabularyError.self) { _ = try await archive.commit(invalid) }
        invalid = original; invalid.sources = []
        await #expect(throws: VocabularyError.self) { _ = try await archive.commit(invalid) }
        let first = UUID(), second = UUID()
        invalid = original
        invalid.catalog = [.init(id: UUID(), expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            senses: [.init(id: first, meaning: "银行", createdAt: now, updatedAt: now),
                     .init(id: second, meaning: "河岸", createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)]
        invalid.catalog[0].senses[0].isSavedWithoutContext = true
        invalid.catalog[0].senses[1].isSavedWithoutContext = true
        await #expect(throws: VocabularyError.self) { _ = try await archive.commit(invalid) }
        invalid.catalog[0].senses[1].isSavedWithoutContext = false
        invalid.interpretations = [.init(id: UUID(), occurrenceID: original.occurrences[0].id, senseID: first,
            status: .accepted, createdAt: now), .init(id: UUID(), occurrenceID: original.occurrences[0].id,
            senseID: second, status: .accepted, createdAt: now)]
        await #expect(throws: VocabularyError.self) { _ = try await archive.commit(invalid) }
        #expect(try await archive.load().document == original)
    }

    @Test func correctingAnExampleForksEvidenceAndLeavesOtherClaimsUntouched() async throws {
        let archive = VocabularyArchive(url: nil)
        let capture = VocabularyCapture(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            example: .init(id: UUID(), sourceKind: .captured, text: "The bank is closed.", translation: "",
                ranges: [.init(NSRange(location: 4, length: 4))], completeness: .sentence, meaning: "银行", createdAt: now))
        let saved = try await archive.save(capture)
        var document = saved.document
        let original = document.interpretations[0]
        document.interpretations.append(.init(id: UUID(), occurrenceID: original.occurrenceID, meaning: "候选解释", createdAt: now))
        _ = try await archive.commit(document)
        let before = document.entries[0]
        var edited = before; edited.senses[0].examples[0].text = "The bank is open."
        let changed = try await archive.update(edited, basedOn: before)
        #expect(changed.document.sources.count == 2 && changed.document.occurrences.count == 2)
        #expect(changed.document.sources[0] == document.sources[0])
        #expect(changed.document.interpretations[1] == document.interpretations[1])
        #expect(changed.document.interpretations[0].id == original.id)
        #expect(changed.document.interpretations[0].occurrenceID != original.occurrenceID)
    }

    @Test func reimportingADeletedWordCreatesANewCorpusEntry() async throws {
        let archive = VocabularyArchive(url: nil)
        let capture = VocabularyCapture(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            meaning: "银行", meaningLanguage: .chinese)
        let initial = try await archive.save(capture)
        _ = try await archive.remove(id: initial.document.entries[0].id)
        let input = VocabularyEntryInput(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
            meaning: "银行", meaningLanguage: .chinese)
        let (restored, result) = try await archive.addEntries([input])
        #expect(result.addedEntries == 1 && result.hasChanges)
        #expect(restored.document.entries.count == 1)
        #expect(restored.document.entries.first?.id != initial.document.entries[0].id)
    }

    @Test func aStaleEditorCannotRecreateADeletedEntry() async throws {
        let archive = VocabularyArchive(url: nil)
        let saved = try await archive.save(.init(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word))
        let baseline = saved.document.entries[0]
        _ = try await archive.remove(id: baseline.id)
        var edited = baseline; edited.senses[0].note = "Stale note"
        await #expect(throws: VocabularyError.editConflict) { _ = try await archive.update(edited, basedOn: baseline) }
        #expect(try await archive.load().document.entries.isEmpty)
    }

    @Test func echoingACapturedSourcePreservesItsExactTimestampAcrossTheCLIUnixEpoch() async throws {
        let archive = VocabularyArchive(url: nil)
        var document = material()
        let source = document.sources[0]
        document.sources[0] = .init(id: source.id, text: source.text, kind: .captured, appBundleIdentifier: nil,
            encounteredAt: Date(timeIntervalSinceReferenceDate: 800_000_000.0000001))
        _ = try await archive.commit(document)
        let wire = try #require(VocabularyCLIResources.records("sources", in: document).first)
        _ = try VocabularyCLIResources.put(.init(resource: "sources", value: wire), in: &document, now: now)
        _ = try VocabularyCLIResources.put(.init(resource: "sources", value: .object(["id": .string(source.id.uuidString)])),
            in: &document, now: now)
        #expect(document.sources[0].encounteredAt == Date(timeIntervalSinceReferenceDate: 800_000_000.0000001))
        let stamp = document.sources[0].encounteredAt
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "金融机构")], createdAt: stamp, updatedAt: stamp)
        document.semantics.nodes = [node]
        _ = try VocabularyCLIResources.put(.init(resource: "nodes", value: .object([
            "id": .string(node.id.uuidString), "definition": .string("A financial institution")
        ])), in: &document, now: now)
        #expect(document.semantics.nodes[0].createdAt == stamp && document.semantics.nodes[0].updatedAt == stamp)
        #expect(try await archive.commit(document).document == document)
    }
}
