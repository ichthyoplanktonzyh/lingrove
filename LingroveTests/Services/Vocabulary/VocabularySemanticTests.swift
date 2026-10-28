import Foundation
import Testing
@testable import Lingrove

/// Real SQLite tests exercise meaning inversion without inference or the user's notebook.
/// The same homograph participates through different senses; evidence always names an exact usage.
@Suite(.serialized)
@MainActor
struct VocabularySemanticTests {
    static func fixture() -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = VocabularyExample(id: UUID(), text: "We pushed the meeting back to Friday.", translation: "会议推迟到周五。",
            translationLanguage: .chinese, ranges: [], completeness: .sentence, meaning: "推迟会议", createdAt: now)
        let delay = VocabularySense(id: UUID(), meaning: "将安排推迟", examples: [usage], createdAt: now, updatedAt: now)
        let resist = VocabularySense(id: UUID(), meaning: "抵制要求", createdAt: now, updatedAt: now)
        let postpone = VocabularySense(id: UUID(), meaning: "延期", createdAt: now, updatedAt: now)
        let entries = [VocabularyEntry(id: UUID(), expression: "push back", dictionaryForm: "push back", language: .english,
            kind: .expression, senses: [delay, resist], createdAt: now, updatedAt: now),
            VocabularyEntry(id: UUID(), expression: "postpone", dictionaryForm: "postpone", language: .english,
                kind: .word, senses: [postpone], createdAt: now, updatedAt: now)]
        let role = VocabularyMeaningRole(name: "event", description: "The scheduled activity")
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "推迟安排", language: .chinese),
            .init(text: "Postponement", language: .english)], definition: "Move an arranged activity to a later time.", roles: [role])
        let opposition = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "抵制要求", language: .chinese)])
        let slot = VocabularyPatternSlot(name: "event", constraint: "An arranged activity")
        let pattern = VocabularyUsagePattern(senseID: delay.id, template: "push [event] back to [time]", slots: [slot])
        let cue = VocabularyRetrievalCue(text: "改一改", language: .chinese)
        let index = VocabularySemanticIndex(nodes: [node, opposition], patterns: [pattern], mappings: [
            .init(nodeID: node.id, senseID: delay.id, patternID: pattern.id, conditions: "An existing schedule",
                roleBindings: [.init(roleID: role.id, slotID: slot.id)], evidenceIDs: [usage.id]),
            .init(nodeID: node.id, senseID: postpone.id),
            .init(nodeID: opposition.id, senseID: resist.id)
        ], cues: [cue], cueTargets: [.init(cueID: cue.id, nodeID: node.id), .init(cueID: cue.id, nodeID: opposition.id)])
        return .init(entries: entries, semantics: index)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func graphRoundTripsThroughRelationalRowsReopenAndBackup() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("meanings.sqlite"), document = Self.fixture()
        let archive = VocabularyArchive(url: url)
        _ = try await archive.commit(document)
        #expect(try await VocabularyArchive(url: url).load().document == document)
        let database = try VocabularySQLiteDatabase(url: url)
        #expect(try database.connection.rows("PRAGMA foreign_key_check").isEmpty)
        for (table, count) in [("sources", 1), ("occurrences", 1), ("meaning_nodes", 2), ("meaning_labels", 3),
                               ("meaning_roles", 1), ("usage_patterns", 1),
                               ("pattern_slots", 1), ("meaning_mappings", 3), ("mapping_roles", 1),
                               ("mapping_evidence", 1), ("retrieval_cues", 1), ("cue_targets", 2)] {
            #expect(try database.connection.rows("SELECT count(*) FROM " + table) == [[.integer(Int64(count))]])
        }
        let backup = folder.appendingPathComponent("backup.lingrove")
        try await archive.backup(to: backup)
        let restored = try await VocabularyArchive(url: folder.appendingPathComponent("restored.sqlite")).restore(from: backup)
        #expect(restored.document == document)
    }

    @Test func searchInvertsSpecificSensesAndAmbiguousCuesRetainMultipleTargets() throws {
        let document = Self.fixture()
        let items = VocabularyMeaningBrowserProjection.items(index: document.semantics, entries: document.entries, query: "推迟安排")
        #expect(items.count == 1 && items[0].selections.count == 2)
        #expect(!items[0].selections.contains { $0.senseID == document.entries[0].senses[1].id })
        let ambiguous = VocabularyMeaningBrowserProjection.items(index: document.semantics, entries: document.entries, query: "改一改")
        #expect(ambiguous.count == 2)
        let graph = VocabularyGraphProjection.meanings(index: document.semantics, entries: document.entries,
            expanded: Set(document.semantics.nodes.map(\.id)), query: "")
        #expect(graph.nodes.count == 5 && graph.edges.count == 3)
        #expect(graph.edges.allSatisfy { $0.kind == .expressesContent })
    }

    @Test func proposedMappingDoesNotRemoveASenseFromUnclassified() {
        var document = Self.fixture()
        document.semantics.mappings[0].provenance.status = .proposed
        let targets = VocabularyMeaningBrowserProjection.unclassified(index: document.semantics, entries: document.entries)
        #expect(targets.map(\.senseID) == [document.entries[0].senses[0].id])
        let graph = VocabularyGraphProjection.meanings(index: document.semantics, entries: document.entries,
            expanded: Set(document.semantics.nodes.map(\.id)), query: "")
        #expect(graph.edges.count == 2)
    }

    @Test func changingASharedCuePreservesOtherNodesAndUnchangedCueLanguages() throws {
        var index = Self.fixture().semantics
        let original = index.cues[0], nodeID = index.nodes[0].id
        index.cueTargets[0].conditions = "For schedule changes"
        var renamed = original; renamed.text = "往后挪"
        VocabularySemanticPolicy.replaceCues([renamed], for: nodeID, in: &index)
        #expect(index.cues.contains(original))
        let target = try #require(index.cueTargets.first { $0.nodeID == nodeID })
        #expect(target.cueID != original.id && target.conditions == "For schedule changes")
        #expect(index.cueTargets.contains { $0.nodeID != nodeID && $0.cueID == original.id })
        let retained = try #require(index.cues.first { $0.id == target.cueID })
        VocabularySemanticPolicy.replaceCues([retained], for: nodeID, in: &index)
        #expect(index.cueTargets.first { $0.nodeID == nodeID }?.cueID == retained.id)
        #expect(retained.language == original.language)
    }

    @Test func foreignKeysRejectMissingMeaningsAndPatternsFromAnotherSense() throws {
        let database = try VocabularySQLiteDatabase(url: nil)
        var document = Self.fixture()
        let wrong = VocabularyUsagePattern(senseID: document.entries[0].senses[1].id, template: "push back against [demand]")
        document.semantics.patterns.append(wrong)
        _ = try database.write(document, previous: .init(), expectedRevision: 0)
        #expect(throws: VocabularyError.self) {
            try database.connection.execute("UPDATE meaning_mappings SET meaning_id='missing'")
        }
        #expect(throws: VocabularyError.self) {
            try database.connection.execute("UPDATE meaning_mappings SET pattern_id=? WHERE id=?",
                [.text(wrong.id.uuidString), .text(document.semantics.mappings[0].id.uuidString)])
        }
        #expect(try database.read().document == document)
    }

    @Test func semanticEditsPreserveUnrelatedConcurrentRecordsAndRejectStaleDefinitions() async throws {
        let archive = VocabularyArchive(url: nil), document = Self.fixture()
        _ = try await archive.commit(document)
        var first = document.semantics; first.nodes[0].definition = "First writer"
        _ = try await archive.updateSemantics(first, basedOn: document.semantics)
        var other = document.semantics; other.nodes[1].definition = "Second writer"
        let saved = try await archive.updateSemantics(other, basedOn: document.semantics)
        #expect(saved.document.semantics.nodes.map(\.definition) == ["First writer", "Second writer"])
        other.nodes[0].definition = "Stale writer"
        await #expect(throws: VocabularyError.editConflict) { try await archive.updateSemantics(other, basedOn: document.semantics) }
    }

    @Test func preferredLabelCanBeReplacedAtomicallyAndNoUsageIsRewritten() throws {
        let database = try VocabularySQLiteDatabase(url: nil), document = Self.fixture()
        let revision = try database.write(document, previous: .init(), expectedRevision: 0)
        let usages = try database.connection.rows("SELECT payload FROM usages")
        var next = document
        next.semantics.nodes[0].labels[0].preferred = false
        next.semantics.nodes[0].labels.append(.init(text: "将安排往后移", language: .chinese))
        _ = try database.write(next, previous: document, expectedRevision: revision)
        #expect(try database.read().document == next)
        #expect(try database.connection.rows("SELECT payload FROM usages") == usages)
    }

    @Test func nodeRemovalOnlyDetachesAssociations() async throws {
        let archive = VocabularyArchive(url: nil), document = Self.fixture()
        _ = try await archive.commit(document)
        var edited = document.semantics
        VocabularySemanticPolicy.removeNode(edited.nodes[0].id, from: &edited)
        let saved = try await archive.updateSemantics(edited, basedOn: document.semantics)
        #expect(saved.document.entries == document.entries)
        #expect(saved.document.semantics.patterns == document.semantics.patterns)
        #expect(saved.document.semantics.mappings.count == 1)
        #expect(VocabularyMeaningBrowserProjection.unclassified(index: saved.document.semantics, entries: document.entries).count == 2)
    }

    @Test func patternRemovalDoesNotBroadenARestrictedAssociation() async throws {
        let archive = VocabularyArchive(url: nil), document = Self.fixture()
        _ = try await archive.commit(document)
        var edited = document.semantics
        VocabularySemanticPolicy.removePattern(edited.patterns[0].id, from: &edited)
        let saved = try await archive.updateSemantics(edited, basedOn: document.semantics)
        #expect(saved.document.semantics.mappings.count == 2)
        #expect(!saved.document.semantics.mappings.contains { $0.senseID == document.entries[0].senses[0].id })
        #expect(saved.document.entries == document.entries)
    }

    @Test func mergingReconcilesTheGraphAndUncollectingPreservesKnowledge() async throws {
        let archive = VocabularyArchive(url: nil), document = Self.fixture()
        _ = try await archive.commit(document)
        let entry = document.entries[0], source = entry.senses[0].id, target = entry.senses[1].id
        let merged = try await archive.mergeSenses(entryID: entry.id, source: source, target: target)
        #expect(merged.document.semantics.patterns[0].senseID == target)
        #expect(merged.document.semantics.mappings[0].senseID == target)
        #expect(merged.document.semantics.mappings[0].evidenceIDs == document.semantics.mappings[0].evidenceIDs)
        let removed = try await archive.removeSense(entryID: entry.id, senseID: target)
        #expect(removed.document.semantics == merged.document.semantics)
        #expect(!removed.document.collectedEntries.contains { $0.senses.contains { $0.id == target } })
        #expect(removed.document.semantics.nodes == document.semantics.nodes)
    }

    @Test func invalidRoleBindingsMixedFunctionMappingsAndHierarchyCyclesAreRejected() throws {
        let document = Self.fixture()
        var index = document.semantics
        index.mappings[0].roleBindings[0].slotID = UUID()
        #expect(throws: VocabularyError.self) { try VocabularySemanticPolicy.validate(index, entries: document.entries) }
        index = document.semantics
        index.nodes[0].kind = .function
        #expect(throws: VocabularyError.self) { try VocabularySemanticPolicy.validate(index, entries: document.entries) }
        index = document.semantics
        let first = index.nodes[0].id, second = index.nodes[1].id
        index.relations = [.init(sourceID: first, targetID: second, kind: .narrower),
            .init(sourceID: second, targetID: first, kind: .narrower)]
        #expect(throws: VocabularyError.self) { try VocabularySemanticPolicy.validate(index, entries: document.entries) }
    }

    @Test func selectedExportKeepsMeaningKnowledgeWithoutLeakingUnselectedSensesOrExamples() async throws {
        let archive = VocabularyArchive(url: nil), document = Self.fixture()
        _ = try await archive.commit(document)
        let selected = VocabularySelection(entryID: document.entries[0].id, senseID: document.entries[0].senses[0].id)
        var options = VocabularyExportConfiguration(); options.format = .json; options.examples = false
        let package = try await archive.prepareExport(selections: [selected], configuration: options)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let exported = try decoder.decode(VocabularyExportDocument.self, from: package.data)
        let graph = try #require(exported.semantics)
        #expect(exported.version == 4 && graph.nodes.count == 1 && graph.mappings.count == 1)
        #expect(graph.mappings[0].evidenceIDs.isEmpty && graph.cueTargets.count == 1)
        #expect(graph.patterns.count == 1 && exported.entries[0].senses.count == 1)
        for format in [VocabularyExportFormat.csv, .text] {
            options.format = format
            let data = try await archive.prepareExport(selections: [selected], configuration: options).data
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.contains("推迟安排") && text.contains("push [event] back to [time]"))
            #expect(!text.contains("抵制要求"))
        }
    }

    @Test func movingAnExampleRemovesItsOldEvidenceClaimWithoutMovingTheMeaning() async throws {
        let archive = VocabularyArchive(url: nil), document = Self.fixture()
        _ = try await archive.commit(document)
        let entry = document.entries[0], example = entry.senses[0].examples[0]
        let moved = try await archive.moveExample(entryID: entry.id, exampleID: example.id,
            source: entry.senses[0].id, target: entry.senses[1].id)
        #expect(moved.document.semantics.mappings[0].evidenceIDs.isEmpty)
        #expect(moved.document.semantics.mappings[0].senseID == entry.senses[0].id)
        #expect(moved.document.entries[0].senses[1].examples.first?.id == example.id)
    }

    @Test func sharedSourceSupportsSeveralOccurrencesAndEditingOneForksItsEvidence() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sources.sqlite")
        let archive = VocabularyArchive(url: url)
        var document = Self.fixture()
        let original = document.entries[0].senses[0].examples[0]
        var occurrence = original.copiedWithNewID()
        occurrence.ranges = [.init((occurrence.text as NSString).range(of: "meeting"))]
        document.entries[1].senses[0].examples = [occurrence]
        _ = try await archive.commit(document)
        let db = try VocabularySQLiteDatabase(url: url)
        #expect(try db.connection.rows("SELECT count(*) FROM sources") == [[.integer(1)]])
        #expect(try db.connection.rows("SELECT count(*) FROM occurrences") == [[.integer(2)]])
        let baseline = document.entries[1]
        var edited = baseline
        edited.senses[0].examples[0].text = "The meeting was moved to Saturday."
        edited.senses[0].examples[0].ranges = []
        let updated = try await archive.update(edited, basedOn: baseline)
        #expect(updated.document.entries[0].senses[0].examples[0] == original)
        #expect(updated.document.entries[1].examples[0].sourceID != original.sourceID)
        #expect(updated.document.entries[1].examples[0].id == occurrence.id)
    }

    @Test func correctingCitedEvidenceWithdrawsTheCitationAndRequiresFreshConfirmation() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("evidence.sqlite"), archive = VocabularyArchive(url: url)
        let document = Self.fixture()
        _ = try await archive.commit(document)
        let backup = folder.appendingPathComponent("before-correction.lingrove")
        try await archive.backup(to: backup)
        let original = document.collectedEntries[0]
        var edited = original
        edited.senses[0].examples[0].text = "They pushed back against the demand."
        let saved = try await archive.update(edited, basedOn: original)
        #expect(saved.document.sources.contains(document.sources[0]))
        #expect(saved.document.interpretations[0].occurrenceID != document.interpretations[0].occurrenceID)
        #expect(saved.document.semantics.mappings[0].evidenceIDs.isEmpty)
        #expect(saved.document.semantics.mappings[0].provenance.status == .proposed)
        #expect(saved.document.semantics.mappings[1] == document.semantics.mappings[1])
        #expect(try await VocabularyArchive(url: url).load().document == saved.document)
        let graph = VocabularyGraphProjection.meanings(index: saved.document.semantics, entries: saved.document.entries,
            expanded: Set(saved.document.semantics.nodes.map(\.id)), query: "")
        #expect(graph.edges.count == 2)
        // Restore is an explicit replacement, including the original confirmed assertion.
        #expect(try await archive.restore(from: backup).document == document)
    }

    @Test func translationEditsKeepEvidenceButReinterpretingTheSameOccurrenceDoesNot() async throws {
        let archive = VocabularyArchive(url: nil), document = Self.fixture()
        _ = try await archive.commit(document)
        var edited = document.collectedEntries[0]
        edited.senses[0].examples[0].translation = "我们将会议推迟到了周五。"
        let translated = try await archive.update(edited, basedOn: document.collectedEntries[0])
        #expect(translated.document.semantics == document.semantics)
        var reinterpreted = translated.document
        reinterpreted.interpretations[0].meaning = "反对要求"
        let saved = try await archive.commit(reinterpreted)
        #expect(saved.document.semantics.mappings[0].evidenceIDs.isEmpty)
        #expect(saved.document.semantics.mappings[0].provenance.status == .proposed)
    }

    @Test func unconfirmedCuesAndRelationsDoNotBecomeSearchOrNavigationFacts() {
        let document = Self.fixture()
        var index = document.semantics
        for offset in index.cueTargets.indices { index.cueTargets[offset].provenance.status = .proposed }
        let relation = VocabularyMeaningRelation(sourceID: index.nodes[0].id, targetID: index.nodes[1].id,
            provenance: .init(origin: .model, status: .proposed))
        index.relations = [relation]
        #expect(VocabularyMeaningBrowserProjection.items(index: index, entries: document.entries, query: "改一改").isEmpty)
        #expect(VocabularyMeaningBrowserProjection.confirmedRelations(in: index).isEmpty)
        #expect(VocabularyGraphProjection.meanings(index: index, entries: document.entries, expanded: [], query: "").edges.isEmpty)
        index.cueTargets[0].provenance.status = .confirmed
        index.relations[0].provenance.status = .confirmed
        #expect(VocabularyMeaningBrowserProjection.items(index: index, entries: document.entries, query: "改一改").count == 1)
        #expect(VocabularyMeaningBrowserProjection.confirmedRelations(in: index).count == 1)
        #expect(VocabularyGraphProjection.meanings(index: index, entries: document.entries, expanded: [], query: "").edges.count == 1)
    }
}
