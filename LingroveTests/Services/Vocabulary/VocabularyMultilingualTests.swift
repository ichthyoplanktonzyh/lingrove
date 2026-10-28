import Foundation
import Testing
@testable import Lingrove

/// A single meaning connects independently owned English, French and Japanese expressions.
/// Real SQLite round trips verify that display preferences never rewrite their source language.
@Suite(.serialized)
struct VocabularyMultilingualTests {
    static func fixture() -> VocabularyDocument {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let node = VocabularyMeaningNode(id: UUID(), labels: [
            .init(text: "Postponement", language: .english), .init(text: "推迟安排", language: .chinese),
            .init(text: "予定の延期", language: .japanese), .init(text: "Report d’un événement", language: .french)
        ], definition: "把原来安排的事项移到更晚的时间")
        let inputs: [(String, LearningLanguage, String)] = [
            ("postpone", .english, "We decided to postpone the meeting."),
            ("reporter", .french, "Nous allons reporter la réunion."),
            ("延期する", .japanese, "会議を延期することにした。")
        ]
        let entries = inputs.map { text, language, sentence in
            VocabularyEntry(id: UUID(), expression: text, dictionaryForm: text, language: language, kind: .word,
                senses: [.init(id: UUID(), meaning: "推迟", meaningLanguage: .chinese,
                    examples: [.init(id: UUID(), text: sentence, translation: "推迟会议。", translationLanguage: .chinese,
                        ranges: [.init((sentence as NSString).range(of: text))], completeness: .sentence, meaning: "推迟",
                        createdAt: now)], createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now)
        }
        let mappings = entries.map { entry in
            VocabularyMeaningMapping(nodeID: node.id, senseID: entry.senses[0].id, evidenceIDs: [entry.examples[0].id])
        }
        return .init(entries: entries, semantics: .init(nodes: [node], mappings: mappings,
            cues: [], cueTargets: []))
    }

    @Test func multilingualMeaningsSurviveReopenAndBackupWithoutLanguageChanges() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("multilingual.sqlite"), document = Self.fixture()
        let archive = VocabularyArchive(url: url)
        _ = try await archive.commit(document)
        let reopened = try await VocabularyArchive(url: url).load().document
        #expect(reopened == document)
        let backup = folder.appendingPathComponent("multilingual.lingrove")
        try await archive.backup(to: backup)
        #expect(try await VocabularyArchive(url: folder.appendingPathComponent("restored.sqlite")).restore(from: backup).document == document)
    }

    @Test func chineseQueryFindsThreeLanguagesAndStudyFilterKeepsTheChineseTitle() throws {
        let document = Self.fixture(), node = document.semantics.nodes[0]
        let all = VocabularyMeaningBrowserProjection.items(index: document.semantics, entries: document.entries,
            query: "推迟安排", preferredLanguages: [.chinese])
        #expect(all.count == 1 && all[0].selections.count == 3 && all[0].title == "推迟安排")
        for language in [LearningLanguage.english, .french, .japanese] {
            let filtered = document.entries.filter { $0.language == language }
            let items = VocabularyMeaningBrowserProjection.items(index: document.semantics, entries: filtered,
                query: "推迟安排", includeEmpty: false, preferredLanguages: [.chinese])
            #expect(items.count == 1 && items[0].id == node.id && items[0].selections.count == 1)
            let graph = VocabularyGraphProjection.meanings(index: document.semantics, entries: filtered,
                expanded: [node.id], query: "", preferredLanguages: [.chinese])
            #expect(graph.nodes.first?.label == "推迟安排" && graph.nodes.count == 2)
            #expect(graph.nodes.last?.id.selection?.senseID == filtered[0].senses[0].id)
        }
    }

    @Test func graphDisambiguatesLanguagesAndUnknownEntriesWithoutGuessing() {
        var document = Self.fixture()
        let now = Date()
        document.entries.append(.init(id: UUID(), expression: "reporter", dictionaryForm: "reporter", language: nil, kind: .word,
            senses: [.init(id: UUID(), meaning: "Unspecified", createdAt: now, updatedAt: now)], createdAt: now, updatedAt: now))
        let node = document.semantics.nodes[0]
        document.semantics.mappings.append(.init(nodeID: node.id, senseID: document.entries[3].senses[0].id))
        let graph = VocabularyGraphProjection.meanings(index: document.semantics, entries: document.entries,
            expanded: [node.id], query: "", preferredLanguages: [.english])
        for entry in document.entries {
            let id = VocabularyGraphNodeID.sense(.init(entryID: entry.id, senseID: entry.senses[0].id))
            #expect(graph.nodes.first { $0.id == id }?.label.contains(
                entry.language?.compactLabel ?? String(localized: "Unspecified", table: "Learning")) == true)
        }
        #expect(document.entries[3].language == nil)
    }

    @Test func identicalSpellingInDifferentLanguagesHasIndependentEntriesAndGraphNodes() async throws {
        let now = Date()
        let entries = [LearningLanguage.english, .french].map { language in
            VocabularyEntry(id: UUID(), expression: "pain", dictionaryForm: "pain", language: language, kind: .word,
                senses: [.init(id: UUID(), meaning: language == .english ? "疼痛" : "面包", createdAt: now, updatedAt: now)],
                createdAt: now, updatedAt: now)
        }
        #expect(VocabularyPolicy.entryKey(entries[0]) != VocabularyPolicy.entryKey(entries[1]))
        let archive = VocabularyArchive(url: nil)
        let saved = try await archive.commit(.init(entries: entries))
        #expect(saved.document.entries.count == 2)
        let graph = VocabularyGraphProjection.make(entries: entries, expanded: [], query: "pain")
        #expect(Set(graph.nodes.map(\.id)).count == 2 && Set(graph.nodes.map(\.label)).count == 2)
    }
}
