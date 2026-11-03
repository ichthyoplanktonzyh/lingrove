import AppKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// Review/Progress presentation tests own this synthetic notebook. It constructs no account,
/// defaults, speech runtime, installed application or global keyboard monitor. The repository
/// is retired only after the test's hosts and session have released their temporary work.
@MainActor
final class ReviewNativePresentationFixture {
    let directory: URL
    let repository: MacNotebookRepository
    let session: BuiltInReviewSession
    let selection: VocabularySelection
    let now = Date(timeIntervalSince1970: 1_793_707_200) // 2026-11-03 12:00 UTC
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-ui-review-" + UUID().uuidString)
        repository = try .init(databaseURL: directory.appendingPathComponent("notebook.sqlite"),
            mediaDirectoryURL: directory.appendingPathComponent("media"))
        let date = now
        let sense = VocabularySense(id: UUID(), meaning: "a sheltered place for boats", meaningLanguage: .english,
            examples: [.init(id: UUID(), text: "The boat entered the harbor before the storm.",
                translation: "A saved example", ranges: [], completeness: .sentence,
                meaning: "a sheltered place for boats", createdAt: date)],
            isSavedWithoutContext: true, createdAt: date, updatedAt: date)
        let entry = VocabularyEntry(id: UUID(), expression: "harbor", dictionaryForm: "harbor", language: .english,
            kind: .word, senses: [sense], createdAt: date, updatedAt: date)
        selection = .init(entryID: entry.id, senseID: sense.id)
        _ = try repository.engine.saveLingroveNotebook(.init(entries: [entry]), basedOn: repository.snapshot())
        session = .init(repository: repository)
    }

    func review() throws -> NotebookBuiltInReviewSnapshot {
        try repository.engine.loadBuiltInNotebookReview(scope: repository.snapshot(), now: now)
    }

    func enroll() throws {
        let content = try review()
        let draft = try LingroveNotebookCardMaterial.draft(snapshot: content.scope, selection: selection)
        _ = try repository.engine.enrollBuiltInNotebookSense(draft, input: draft.generatedContent,
            action: .init(content: content, selection: selection))
    }

    func rate(_ rating: ReviewRating, date: Date) throws {
        let content = try review()
        let card = try #require(content.review.groups[selection.senseID]?.cards.first)
        _ = try repository.engine.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: rating,
            reviewedAtClient: formatIsoTimestamp(date: date), reviewedTimeZone: "UTC"), card: card,
            action: .init(content: content, selection: selection))
    }

    /// Real enrollment/rating commands prepare history. Only fixture due timestamps are moved
    /// afterward, with their matching millis, to make all eight forecast categories visible.
    func seedProgress() throws {
        try enroll()
        for (index, rating) in ReviewRating.allCases.enumerated() {
            try rate(rating, date: now.addingTimeInterval(Double(index - 4) * 60))
        }
        let first = try #require(review().review.groups[selection.senseID]?.cards.first)
        try setDue(first, days: 1)
        let offsets: [Int?] = [nil, 0, 8, 31, 91, 361, 721]
        for days in offsets {
            var content = try review()
            let draft = try LingroveNotebookCardMaterial.draft(snapshot: content.scope, selection: selection)
            let card = try repository.engine.addBuiltInNotebookExercise(draft, input: draft.generatedContent,
                action: .init(content: content, selection: selection))
            if let days {
                content = try review()
                _ = try repository.engine.submitBuiltInNotebookRating(.init(cardId: card.cardId, rating: .good,
                    reviewedAtClient: formatIsoTimestamp(date: now.addingTimeInterval(-10)), reviewedTimeZone: "UTC"),
                    card: card, action: .init(content: content, selection: selection))
                try setDue(card, days: days)
            }
        }
    }

    func progressModel(reader: (any NotebookProgressReading)? = nil) -> NotebookProgressModel {
        let date = now
        let calendar = calendar
        return .init(repository: repository, reader: reader, now: { date }, calendar: { calendar })
    }

    private func setDue(_ card: Card, days: Int) throws {
        let due = try #require(calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)))
        try repository.engine.core.execute(sql: "UPDATE cards SET due_at=?,due_at_millis=? WHERE workspace_id=? AND card_id=?",
            values: [.text(formatIsoTimestamp(date: due)), .integer(Int64(due.timeIntervalSince1970 * 1_000)),
                .text(card.workspaceId), .text(card.cardId)])
    }

    func cleanUp() {
        session.close()
        try? repository.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Each test owns one real native host. Appearance is set on this private NSWindow, never on
/// the SwiftUI content or NSApp, so these checks exercise inherited Aqua/darkAqua resolution.
/// Captures are native content artifacts; full compositor and pointer journeys remain separate.
@MainActor
final class ReviewNativePresentationHost {
    let window: NSWindow
    let view: NSHostingView<AnyView>
    let appearance: NSAppearance.Name

    init(_ content: some View, appearance: NSAppearance.Name, size: CGSize) {
        self.appearance = appearance
        view = NSHostingView(rootView: AnyView(content))
        window = NSWindow(contentRect: .init(x: 100, y: 100, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Lingrove UI Review Validation"
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        for sheet in window.sheets { window.endSheet(sheet) }
        window.contentView = nil
        window.close()
    }

    func settle() async throws {
        for _ in 0..<6 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    }

    func capture(_ name: String, window target: NSWindow? = nil) throws {
        guard let output = ProcessInfo.processInfo.environment["LINGROVE_UI_REVIEW_EVIDENCE_DIR"] else { return }
        let target = target ?? window
        let native = try #require(target.contentView)
        native.layoutSubtreeIfNeeded()
        #expect(native.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
        let bitmap = try #require(native.bitmapImageRepForCachingDisplay(in: native.bounds))
        native.cacheDisplay(in: native.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 1_000)
        let path = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let suffix = appearance == .aqua ? "aqua" : "dark-aqua"
        try png.write(to: path.appendingPathComponent(name + "-" + suffix + ".png"))
    }

}
