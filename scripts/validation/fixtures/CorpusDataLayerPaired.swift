/// Release-only, synthetic engine benchmark. The runner compiles this same source against
/// each revision and feeds byte-identical closed SQLite seed copies to both executables.
import Foundation
import LingroveNotebook
import LingroveNotebookEngine

func identifier(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", number))!
}

func main() throws {
    let args = CommandLine.arguments
    let folder = URL(fileURLWithPath: args[2])
    let db = try LingroveNotebookEngine(databaseURL: folder.appendingPathComponent("primary.sqlite"),
        mediaDirectoryURL: folder.appendingPathComponent("Media"))
    defer { try? db.close() }
    guard let workspace = try db.workspaceSettingsStore.loadCloudSettings().activeWorkspaceId else { fatalError("No synthetic workspace") }
    let count = Int(args[3])!
    if args[1] == "seed" {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let entries: [VocabularyEntry] = (0..<count).map { index in
            .init(id: identifier(1_000_000 + index), expression: "word\(index)", dictionaryForm: "word\(index)",
                language: index % 5 == 0 ? .french : .english, kind: .word,
                senses: (0..<2).map { sense in
                    let ordinal = index * 2 + sense
                    return .init(id: identifier(2_000_000 + ordinal), meaning: "Synthetic meaning \(ordinal)",
                        meaningLanguage: .chinese, note: "Synthetic personal note \(ordinal)", tags: ["group-\(index % 20)"],
                        examples: (0..<2).map { example in
                            .init(id: identifier(3_000_000 + ordinal * 2 + example), sourceKind: .authored,
                                text: "I used word\(index) in synthetic context \(sense)-\(example).",
                                translation: "合成例句译文 \(ordinal)-\(example)", ranges: [], completeness: .sentence,
                                meaning: "Contextual definition \(ordinal)", createdAt: date)
                        }, createdAt: date, updatedAt: date)
                }, createdAt: date.addingTimeInterval(Double(index)), updatedAt: date)
        }
        var document = VocabularyDocument(entries: entries)
        let nodes: [VocabularyMeaningNode] = (0..<(count * 14 / 10)).map {
            .init(id: identifier(4_000_000 + $0), labels: [.init(text: "Meaning \($0)", language: .english)],
                definition: "Synthetic definition \($0)", createdAt: date, updatedAt: date)
        }
        document.semantics = .init(nodes: nodes, mappings: nodes.enumerated().map {
            .init(nodeID: $0.element.id, senseID: identifier(2_000_000 + $0.offset))
        })
        document.classification.categories = (0..<max(1, count * 35 / 1000)).map {
            .init(id: identifier(5_000_000 + $0), axis: .content, labels: [.init(text: "Category \($0)")])
        }
        document.classification.memberships = nodes.enumerated().map {
            .init(id: identifier(7_000_000 + $0.offset), nodeID: $0.element.id,
                categoryID: identifier(5_000_000 + $0.offset % max(1, count * 35 / 1000)))
        }
        try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: nodes)
        let saved = try db.saveLingroveNotebook(document, basedOn: db.loadLingroveNotebook(workspaceId: workspace))
        let selections = stride(from: 0, to: count, by: 5).map {
            VocabularySelection(entryID: entries[$0].id, senseID: entries[$0].senses[0].id)
        }
        _ = try db.enrollReviewNotes(selections: selections, version: .init(saved))
        let review = try db.loadBuiltInNotebookReview(scope: saved, now: Date())
        for card in review.queue.prefix(1_000) {
            let question = review.noteCards[card.cardId]!
            _ = try db.submitNotebookRating(.init(cardId: card.cardId, rating: .good, reviewedAtClient: nowIsoTimestamp(),
                reviewedTimeZone: "UTC", noteVersion: question.questionVersion(in: saved)), basedOn: saved)
        }
        print("Seed \(count) entries, two senses and four examples per entry")
        return
    }
    var scope = try db.loadLingroveNotebook(workspaceId: workspace)
    var samples: [String: Double] = [:]
    func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        let result = try body()
        let elapsed = start.duration(to: .now).components
        samples[name] = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        return result
    }
    var entry = scope.document.entries[53]
    entry.senses[0].note = "A paired narrow edit"
    scope = try measure("entry_save_ms") { try db.saveNotebookEntry(entry, basedOn: scope) }
    var full = scope.document
    full.catalog[54].senses.append(.init(id: identifier(9_000_000), meaning: "New synthetic sense", createdAt: Date(), updatedAt: Date()))
    scope = try measure("full_save_ms") { try db.saveLingroveNotebook(full, basedOn: scope) }
    scope = try measure("read_after_full_save_ms") { try db.loadLingroveNotebook(workspaceId: workspace) }
    scope = try measure("remove_front_ms") {
        try db.removeNotebookSense(identifier(2_000_000 + 58 * 2), from: identifier(1_000_000 + 58), basedOn: scope)
    }
    scope = try measure("remove_tail_ms") {
        try db.removeNotebookSense(identifier(2_000_000 + (count - 2) * 2), from: identifier(1_000_000 + count - 2), basedOn: scope)
    }
    precondition(scope.document.entries.first { $0.id == entry.id }?.senses.first?.note == "A paired narrow edit")
    precondition(scope.document.entries.first { $0.id == identifier(1_000_054) }?.senses.count == 3)
    let events = try db.loadReviewEventCount()
    precondition(events == 1000)
    print(String(decoding: try JSONEncoder().encode(samples), as: UTF8.self))
}
try main()
