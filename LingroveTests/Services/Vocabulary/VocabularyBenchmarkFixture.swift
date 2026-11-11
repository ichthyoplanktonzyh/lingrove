import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import Testing
@testable import Lingrove

/// The benchmark owns generated SQLite files, never a discovered application path. Each trial
/// copies a closed seed, then owns the same repository/store/review collaborators as the app.
/// Keeping setup outside the timer separates corpus construction from a user's actual command.
@MainActor
final class VocabularyBenchmarkFixture {
    let directory: URL
    let repository: MacNotebookRepository
    let store: VocabularyStore
    let review: BuiltInReviewSession
    let progress: NotebookProgressModel

    init(seed: URL, directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: seed, to: directory.appendingPathComponent("primary.sqlite"))
        repository = try MacNotebookRepository(databaseURL: directory.appendingPathComponent("primary.sqlite"),
            mediaDirectoryURL: directory.appendingPathComponent("Media"))
        store = VocabularyStore(repository: repository)
        review = BuiltInReviewSession(repository: repository)
        review.materialStore = store
        progress = NotebookProgressModel(repository: repository)
    }

    func close() async {
        progress.setActive(false)
        await review.shutdownAfterDraining()
        await store.shutdown()
        try? repository.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    func entry(_ index: Int) throws -> VocabularyEntry {
        try #require(store.readIndex.entriesByID[Self.id(1_000_000 + index)])
    }

    static func id(_ number: Int) -> UUID {
        // Fixed IDs make graph shape, ordering and mutation targets identical between trials.
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", number))!
    }

    static func capture(_ name: String, example: Bool = false) -> VocabularyCapture {
        var result = VocabularyCapture(expression: name, dictionaryForm: name, language: .english,
            kind: .word, meaning: "Synthetic saved translation", meaningLanguage: .chinese)
        if example {
            result.example = .init(id: UUID(), sourceKind: .authored,
                text: "I used \(name) in a synthetic sentence.", translation: "这是一条合成译文。",
                ranges: [], completeness: .sentence, meaning: "Synthetic contextual meaning", createdAt: Date())
        }
        return result
    }

    /// Public engine commands create valid content, enrollments and historical ratings. Seeding
    /// is deliberately untimed; raw SQL shortcuts could produce a fast but invalid benchmark.
    static func seed(entries count: Int, at directory: URL) throws -> [String: Int] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let engine = try LingroveNotebookEngine(databaseURL: directory.appendingPathComponent("primary.sqlite"),
            mediaDirectoryURL: directory.appendingPathComponent("Media"))
        defer { try? engine.close() }
        let workspace = try #require(engine.workspaceSettingsStore.loadCloudSettings().activeWorkspaceId)
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        var entries: [VocabularyEntry] = []
        for index in 0..<count {
            var senses: [VocabularySense] = []
            for sense in 0..<2 {
                let ordinal = index * 2 + sense
                let examples: [VocabularyExample] = (0..<2).map { example in
                    .init(id: id(3_000_000 + ordinal * 2 + example), sourceKind: .authored,
                        text: "I used word\(index) in synthetic context \(sense)-\(example).",
                        translation: "合成例句译文 \(ordinal)-\(example)", ranges: [], completeness: .sentence,
                        meaning: "Contextual definition \(ordinal)", createdAt: date)
                }
                senses.append(.init(id: id(2_000_000 + ordinal), meaning: "Synthetic meaning \(ordinal)",
                    meaningLanguage: .chinese, note: "Synthetic personal note \(ordinal)",
                    tags: ["group-\(index % 20)", "benchmark-common"], examples: examples,
                    createdAt: date, updatedAt: date))
            }
            entries.append(.init(id: id(1_000_000 + index), expression: "word\(index)", dictionaryForm: "word\(index)",
                language: index % 5 == 0 ? .french : .english, kind: .word, senses: senses,
                createdAt: date.addingTimeInterval(Double(index)), updatedAt: date))
        }
        let nodes: [VocabularyMeaningNode] = (0..<(count * 14 / 10)).map { index in
            .init(id: id(4_000_000 + index), labels: [.init(text: "Meaning \(index)", language: .english)],
                definition: "Synthetic semantic definition \(index)", createdAt: date, updatedAt: date)
        }
        let categoryCount = max(4, count * 35 / 1_000)
        let roots = max(1, categoryCount / 7)
        var classification = VocabularyClassificationIndex()
        classification.categories = (0..<categoryCount).map { index in
            .init(id: id(5_000_000 + index), axis: .content, labels: [.init(text: "Category \(index)")])
        }
        classification.parents = (roots..<categoryCount).map { index in
            .init(id: id(6_000_000 + index), categoryID: id(5_000_000 + index), parentID: id(5_000_000 + index % roots))
        }
        classification.memberships = nodes.enumerated().map { index, node in
            .init(id: id(7_000_000 + index), nodeID: node.id, categoryID: id(5_000_000 + index % categoryCount))
        }
        let mappings = nodes.enumerated().map { index, node in
            VocabularyMeaningMapping(nodeID: node.id, senseID: id(2_000_000 + index))
        } + (1..<12).map { VocabularyMeaningMapping(nodeID: nodes[0].id, senseID: id(2_000_000 + $0)) }
        var document = VocabularyDocument(entries: entries)
        document.semantics = .init(nodes: nodes, mappings: mappings)
        document.classification = classification
        try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: nodes)
        let saved = try engine.saveLingroveNotebook(document, basedOn: engine.loadLingroveNotebook(workspaceId: workspace))
        let selections = stride(from: 0, to: count, by: 5).map { index in
            VocabularySelection(entryID: entries[index].id, senseID: entries[index].senses[0].id)
        }
        _ = try engine.enrollReviewNotes(selections: selections, version: .init(saved))
        let content = try engine.loadBuiltInNotebookReview(scope: saved, now: Date())
        let historyCount = min(1_000, selections.count / 2)
        for card in content.queue.prefix(historyCount) {
            let question = try #require(content.noteCards[card.cardId])
            _ = try engine.submitNotebookRating(.init(cardId: card.cardId, rating: .good,
                reviewedAtClient: formatIsoTimestamp(date: Date()),
                reviewedTimeZone: "UTC", noteVersion: try question.questionVersion(in: saved)), basedOn: saved)
        }
        return ["entries": count, "senses": count * 2, "examples": count * 4,
            "meanings": nodes.count, "mappings": mappings.count,
            "categories": document.classification.categories.count,
            "categoryMemberships": classification.memberships.count,
            "enrolledSenses": selections.count, "ratingRecords": historyCount]
    }
}
