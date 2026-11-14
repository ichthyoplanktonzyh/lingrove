import AppKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// The native adapter is exercised with a private SQLite repository and deterministic speech.
/// These tests protect recipe ownership and real round transitions, without connecting to Anki
/// or treating a compiled view as proof of persistence or user interaction.
@Suite(.serialized)
@MainActor
struct BuiltInReviewExperienceTests {
    @Test func addNavigationRetainsSearchAndSeparatesParticipation() async throws {
        let fixture = try ReviewNativePresentationFixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        session.open(selection: nil); await session.waitForIdle()
        session.showAdding()
        session.browsing.addingSearch = "harbor"
        session.showDetail(fixture.selection)
        #expect(session.browsing.detailOrigin == .adding)
        #expect(try fixture.review().statistics.exercises == 0)
        session.enrollDefault(selection: fixture.selection, basedOn: try #require(session.content))
        await session.waitForIdle()
        #expect(session.addedCount == 1 && session.practice == nil)
        session.route = try #require(session.browsing.detailOrigin)
        #expect(session.route == .adding && session.browsing.addingSearch == "harbor")
        let added = try #require(session.content)
        #expect(BuiltInReviewContentState(added).selections(adding: true, filter: .active, search: "").isEmpty)
        #expect(BuiltInReviewContentState(added).selections(adding: false, filter: .active, search: "harbor")
            == [fixture.selection])
        session.setStatus(.paused, selection: fixture.selection, basedOn: added)
        await session.waitForIdle()
        let paused = try #require(session.content)
        #expect(BuiltInReviewContentState(paused).selections(adding: false, filter: .active, search: "").isEmpty)
        #expect(BuiltInReviewContentState(paused).selections(adding: false, filter: .paused, search: "")
            == [fixture.selection])
        session.setStatus(.withdrawn, selection: fixture.selection, basedOn: paused)
        await session.waitForIdle()
        let withdrawn = try #require(session.content)
        #expect(BuiltInReviewOverviewState(content: withdrawn) == .withdrawn)
        #expect(BuiltInReviewContentState(withdrawn).selections(adding: false, filter: .withdrawn, search: "")
            == [fixture.selection])
        session.showContent(filter: .withdrawn)
        session.browsing.search = "harbor"
        session.showDetail(fixture.selection)
        session.route = try #require(session.browsing.detailOrigin)
        #expect(session.route == .content && session.browsing.filter == .withdrawn && session.browsing.search == "harbor")
        session.close()
        #expect(session.browsing.search.isEmpty && session.browsing.addingSearch.isEmpty)
    }

    @Test func managementClearsFilteredDetailButDirectSourceRemainsReachable() async throws {
        let fixture = try ReviewNativePresentationFixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        session.open(selection: fixture.selection)
        await session.waitForIdle()
        #expect(session.route == .sense(fixture.selection))
        #expect(session.browsing.detailOrigin == nil)

        session.enrollDefault(selection: fixture.selection, basedOn: try #require(session.content))
        await session.waitForIdle()
        session.showDetail(fixture.selection)
        session.browsing.search = "no such expression"
        #expect(session.route == .content && session.contentSelections.isEmpty)

        session.browsing.search = ""
        session.showDetail(fixture.selection)
        session.setStatus(.paused, selection: fixture.selection, basedOn: try #require(session.content))
        await session.waitForIdle()
        #expect(session.route == .content && session.contentSelections.isEmpty)
        session.showContent(filter: .paused)
        #expect(session.contentSelections == [fixture.selection])
    }


    @Test func addingBatchReturnsToPickerWithoutStartingPractice() async throws {
        let fixture = try ReviewNativePresentationFixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        session.open(selection: nil); await session.waitForIdle()
        session.showAdding()
        session.browsing.selectedSenseIDs.insert(fixture.selection.senseID)
        session.requestBatch([fixture.selection])
        #expect(try fixture.review().statistics.exercises == 0)
        session.saveBatch(try #require(session.batchDraft)); await session.waitForIdle()
        #expect(session.route == .adding && session.practice == nil)
        #expect(session.addedCount == 1 && session.browsing.selectedSenseIDs.isEmpty)
        #expect(try fixture.review().statistics.exercises == 1)
    }

    @Test func ordinaryOpenShowsOverviewAndCompletionRequiresAnAnsweredRound() async throws {
        let fixture = try ReviewNativePresentationFixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        session.open(selection: nil)
        await session.waitForIdle()
        #expect(session.route == .overview && session.practice == nil)
        #expect(BuiltInReviewOverviewState(content: try #require(session.content)) == .noSelection)
        session.start()
        #expect(session.route == .overview && session.practice == nil)
        session.enrollDefault(selection: fixture.selection, basedOn: try #require(session.content))
        await session.waitForIdle()
        #expect(BuiltInReviewOverviewState(content: try #require(session.content)) == .due)
        session.setStatus(.paused, selection: fixture.selection, basedOn: try #require(session.content))
        await session.waitForIdle()
        #expect(BuiltInReviewOverviewState(content: try #require(session.content)) == .paused)
        session.setStatus(.active, selection: fixture.selection, basedOn: try #require(session.content))
        await session.waitForIdle()
        session.start(selection: fixture.selection)
        #expect(session.practice?.initialDueCount == 1 && session.practice?.answered == 0)
        session.reveal(); session.rate(.good)
        await session.waitForIdle()
        #expect(session.practice?.answered == 1)
        guard case .finished = session.practice?.phase else { Issue.record("The rated round did not finish"); return }
        session.close(); session.open(selection: nil)
        await session.waitForIdle()
        #expect(session.route == .overview && session.practice == nil)
        guard case .scheduled = BuiltInReviewOverviewState(content: try #require(session.content)) else {
            Issue.record("A scheduled sense must not look like a newly finished round"); return
        }
    }


    @Test func batchEnrollmentResumesExistingParticipationWithoutDuplicatingExercisesOrHistory() async throws {
        let fixture = try ReviewNativePresentationFixture(); defer { fixture.cleanUp() }
        let store = VocabularyStore(repository: fixture.repository)
        await store.load()
        await store.save(.init(expression: "anchor", dictionaryForm: "anchor", language: .english,
            kind: .word, meaning: "a device securing a boat", meaningLanguage: .english))
        let entry = try #require(store.entries.first { $0.expression == "anchor" })
        let second = VocabularySelection(entryID: entry.id, senseID: try #require(entry.senses.first).id)
        let session = fixture.session
        session.open(selection: nil); await session.waitForIdle()
        session.requestBatch([fixture.selection, second])
        session.saveBatch(try #require(session.batchDraft)); await session.waitForIdle()
        #expect(try fixture.review().statistics.exercises == 2)
        session.start(selection: fixture.selection); session.reveal(); session.rate(.good); await session.waitForIdle()
        session.endPractice()
        session.setStatus(.withdrawn, selection: fixture.selection, basedOn: try #require(session.content))
        await session.waitForIdle()
        session.requestBatch([fixture.selection, second])
        session.saveBatch(try #require(session.batchDraft)); await session.waitForIdle()
        let content = try #require(session.content)
        #expect(content.statistics.exercises == 2 && content.statistics.ratingRecords == 1)
        #expect(content.review.groups[fixture.selection.senseID]?.status == .active)
        #expect(content.review.groups[fixture.selection.senseID]?.cards.first?.reps == 1)
        await store.shutdown()
    }

    @Test func materialEditReturnsToItsPracticeWithoutCountingAnAnswer() async throws {
        let fixture = try ReviewNativePresentationFixture(); defer { fixture.cleanUp() }
        let session = fixture.session
        session.open(selection: fixture.selection); await session.waitForIdle()
        session.enrollDefault(selection: fixture.selection, basedOn: try #require(session.content))
        await session.waitForIdle()
        session.start(); session.reveal()
        let context = try #require(session.practice?.phase.context)
        session.editNoteType(try #require(context.action.noteCards[context.card.cardId]).noteType)
        var draft = try #require(session.noteTypeDraft)
        draft.type.templates[0].front = "A revised practice prompt"
        session.saveNoteType(draft); await session.waitForIdle()
        #expect(session.route == .practice && session.practice?.answered == 0)
        guard case let .question(current) = session.practice?.phase else { Issue.record("An edited question must be shown again"); return }
        #expect(current.card.cardId == context.card.cardId && current.card.frontText == "A revised practice prompt")
        #expect(try fixture.review().statistics.ratingRecords == 0)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func sharedEditorAndToolDestinationsRenderInInheritedAppearance(_ appearance: NSAppearance.Name) async throws {
        let fixture = try NotebookWorkspaceFixture()
        do {
        let selection = try await fixture.seed()
        fixture.window.showReview(selection: selection); await fixture.review.session.waitForIdle()
        let window = try #require(fixture.window.window)
        let original = NSApp.appearance
        window.appearance = NSAppearance(named: appearance)
        fixture.review.session.editNoteType()
        try await Task.sleep(for: .milliseconds(200))
        try capture(window: try #require(window.attachedSheet), name: "shared-material-editor", appearance: appearance)
        #expect(window.attachedSheet != nil)
        fixture.review.session.noteTypeDraft = nil
        try await Task.sleep(for: .milliseconds(100))
        await fixture.anki.testConnection()
        fixture.window.reviewNavigation.target = .anki
        try await Task.sleep(for: .milliseconds(150))
        try capture(window: window, name: "review-anki-destination", appearance: appearance)
        #expect(fixture.anki.catalog != nil)
        #expect(fixture.review.session.practice == nil)
        #expect(NSApp.appearance === original)
        fixture.window.reviewNavigation.target = .lingrove
        await fixture.review.session.waitForIdle()
        #expect(fixture.review.session.route == .sense(selection))
        fixture.review.session.route = .overview
        try await Task.sleep(for: .milliseconds(100))
        try capture(window: window, name: "review-lingrove-overview", appearance: appearance)
        fixture.window.onShowSettings?()
        let settings = try #require(fixture.settings)
        let settingsWindow = try #require(fixture.settingsWindow)
        settingsWindow.appearance = NSAppearance(named: appearance)
        settings.navigation.openLearningTask(.review)
        try await Task.sleep(for: .milliseconds(200))
        try capture(window: settingsWindow, name: "review-settings-lingrove", appearance: appearance)
        settings.showReviewSettings()
        try await Task.sleep(for: .milliseconds(200))
        #expect(settings.navigation.revealedItem == .ankiReview)
        try capture(window: settingsWindow, name: "review-settings-anki", appearance: appearance)
        } catch { await fixture.cleanUp(); throw error }
        await fixture.cleanUp()
    }

    private func capture(window: NSWindow, name: String, appearance: NSAppearance.Name) throws {
        guard let output = ProcessInfo.processInfo.environment["LINGROVE_REVIEW_EVIDENCE_DIR"] else { return }
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name + (appearance == .aqua ? "-aqua.png" : "-dark-aqua.png")))
    }
}
