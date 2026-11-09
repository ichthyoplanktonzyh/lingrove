import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import Testing
@testable import Lingrove

/// The final app assembly is exercised with actual capture, review IO and SQLite, without
/// constructing the unrelated Accessibility/model graph or touching installed app data.
@Suite(.serialized)
@MainActor
struct MacNotebookAppServicesTests {
    @Test func captureAndExplicitReviewShareOneRepositoryAcrossShutdownAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "lingrove.mac-composition." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let account = AccountSessionService(client: AccountAPIClient(),
            credentials: KeychainAccountCredentialStore(bundleIdentifier: suite),
            settings: AccountConfigurationStore(defaults: defaults))
        let database = directory.appendingPathComponent("primary.sqlite")
        let media = directory.appendingPathComponent("media")
        let services = MacNotebookAppServices(databaseURL: database, mediaDirectoryURL: media, account: account)
        let repository = try #require(services.repository)
        #expect(services.synchronization?.repository === repository)
        #expect(services.vocabulary.onRequestBuiltInReview != nil && services.builtInReview != nil)
        services.start()
        await services.vocabulary.save(.init(expression: "serendipity", dictionaryForm: "serendipity",
            language: .english, kind: .word))
        let original = try #require(services.vocabulary.entries.first)
        var edited = original
        edited.senses[0].meaning = "a happy discovery"
        #expect(await services.vocabulary.update(edited, basedOn: original))
        await services.vocabulary.load()
        let saved = try repository.snapshot()
        let selection = VocabularySelection(entryID: edited.id, senseID: edited.senses[0].id)
        #expect(try repository.engine.loadLingroveNotebookReviewEnrollments(workspaceId: saved.workspaceId).isEmpty)
        let review = BuiltInReviewSession(repository: repository)
        review.open(selection: selection)
        await review.waitForIdle()
        let initial = try #require(review.content)
        let current = try repository.snapshot()
        let ready = !review.isBusy && current == initial.scope
        try #require(ready)
        review.enrollDefault(selection: selection, basedOn: initial)
        await review.waitForIdle()
        let enrolled = review.content?.statistics.activeSenses ?? -1
        let enrollmentMessage = review.message ?? "none"
        #expect(enrollmentMessage == "none")
        try #require(enrolled == 1)
        review.start()
        review.reveal()
        review.rate(.good)
        let ratingAdmitted = review.isMutating
        try #require(ratingAdmitted)
        review.prepareForShutdown()
        review.close() // Closing during the earlier CLI-drain interval must not cancel the writer.
        await review.shutdownAfterDraining()
        #expect(try repository.engine.loadReviewEvents(workspaceId: saved.workspaceId).count == 1)
        // Window closure leaves the corpus service active; only app termination drains it.
        await services.vocabulary.load()
        let before = try #require(services.vocabulary.entries.first)
        var after = before
        after.senses[0].note = "edited after closing review"
        #expect(await services.vocabulary.update(after, basedOn: before))
        await services.shutdown()
        await services.shutdown()
        let reopened = try MacNotebookRepository(databaseURL: database, mediaDirectoryURL: media)
        defer { try? reopened.shutdown() }
        let persisted = try reopened.snapshot()
        #expect(persisted.document.entries[0].senses[0].note == after.senses[0].note)
        let result = try reopened.engine.loadBuiltInNotebookReview(scope: persisted, now: Date())
        #expect(result.statistics.activeSenses == 1 && result.statistics.ratingRecords == 1)
        #expect(result.review.groups[selection.senseID]?.cards.first?.reps == 1)
    }

    @Test func unreadableDatabaseIsPreservedAndCaptureFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("primary.sqlite")
        let bytes = Data("not a SQLite database".utf8)
        try bytes.write(to: database)
        let suite = "lingrove.mac-unavailable." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = AccountSessionService(client: AccountAPIClient(),
            credentials: KeychainAccountCredentialStore(bundleIdentifier: UUID().uuidString),
            settings: AccountConfigurationStore(defaults: defaults))
        let services = MacNotebookAppServices(databaseURL: database,
            mediaDirectoryURL: directory.appendingPathComponent("media"), account: account)
        #expect(services.repository == nil && services.synchronization == nil && services.builtInReview == nil)
        await services.vocabulary.save(.init(expression: "blocked", dictionaryForm: "blocked", language: .english, kind: .word))
        #expect(services.vocabulary.entries.isEmpty && services.vocabulary.errorMessage != nil)
        #expect(try Data(contentsOf: database) == bytes)
        await services.shutdown()
    }
}
