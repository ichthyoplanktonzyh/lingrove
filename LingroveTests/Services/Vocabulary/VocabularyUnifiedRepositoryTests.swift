import AppKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import LingroveStudyExport
import Testing
import SwiftUI
@testable import Lingrove

/// The native adapter operates against the app-owned engine and its real SQLite file. Each
/// fixture owns its paths and synthetic settings, so these checks cannot touch a user's corpus.
@Suite(.serialized)
@MainActor
struct VocabularyUnifiedRepositoryTests {
    @Test func cachedArchiveSeesExternalCommitsAndRejectsRetiredGenerationWithoutNotification() async throws {
        try await withFixture { f in
            await f.store.save(.init(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
                meaning: "a financial institution", meaningLanguage: .english))
            let original = try f.repository.snapshot()
            let archive = VocabularyArchive(url: f.repository.databaseURL, mediaDirectoryURL: f.repository.mediaDirectoryURL)
            #expect(try await archive.load().scope == original)
            let other = try LingroveNotebookEngine(databaseURL: f.repository.databaseURL,
                mediaDirectoryURL: f.repository.mediaDirectoryURL)
            defer { try? other.close() }
            var edited = original.document
            edited.entries[0].senses[0].note = "committed by another connection"
            let changed = try other.saveLingroveNotebook(edited, basedOn: original)
            #expect(try await archive.load().scope == changed)
            try other.updateCloudSettings(cloudState: .linked, linkedUserId: "new-synthetic-owner",
                linkedWorkspaceId: original.workspaceId, activeWorkspaceId: original.workspaceId, linkedEmail: nil)
            let fresh = try f.repository.snapshot()
            #expect(fresh.revision == changed.revision && fresh.generation != changed.generation)
            #expect(try await archive.load().scope == fresh)
            await #expect(throws: VocabularyError.editConflict) {
                try await archive.perform(basedOn: LingroveNotebookVersion(changed)) { try $0.load() }
            }
            await f.store.save(.init(expression: "must not write", dictionaryForm: "must not write",
                language: .english, kind: .word), scope: original)
            #expect(try f.repository.snapshot() == fresh)
        }
    }

    @Test func explicitCaptureDraftMergeMediaBackupAndRestartUseTheSameEngine() async throws {
        try await withFixture { f in
            await f.store.load()
            let capture = VocabularyCapture(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word,
                meaning: "a financial institution", meaningLanguage: .english)
            await f.store.save(capture)
            let original = try #require(f.store.entries.first)
            let baseline = try #require(f.store.operationScope)
            #expect(try f.repository.snapshot().document.collectedEntries == f.store.entries)
            #expect(try f.repository.engine.loadLingroveNotebookReviewEnrollments(workspaceId: baseline.workspaceId).isEmpty)
            let initialSequence = f.repository.changeSequence
            var cancelled = original
            cancelled.senses[0].note = "cancelled draft"
            #expect(try f.repository.snapshot().document.collectedEntries[0].senses[0].note.isEmpty)
            let png = try await f.store.prepareImage(VocabularyImageTestFixture.png())
            var edited = original
            edited.senses[0].note = "authored on Mac"
            edited.senses[0].content = [.init(content: .image(png.reference, caption: "Synthetic river"))]
            #expect(await f.store.update(edited, basedOn: original, importedImages: [png.reference.filename: png.data], scope: baseline))
            #expect(f.repository.changeSequence > initialSequence)
            var unrelated = try #require(f.store.entries.first)
            unrelated.dictionaryForm = "bank (noun)"
            #expect(await f.store.update(unrelated, basedOn: try #require(f.store.entries.first), scope: baseline))
            // The original sheet may merge an independent field without losing the intervening note/image.
            var oldSheet = original
            oldSheet.senses[0].tags = ["finance"]
            #expect(await f.store.update(oldSheet, basedOn: original, scope: baseline))
            let saved = try f.repository.snapshot()
            #expect(saved.document.collectedEntries[0].senses[0].note == "authored on Mac")
            #expect(saved.document.collectedEntries[0].dictionaryForm == "bank (noun)")
            #expect(await f.store.image(png.reference, scope: saved) == png.data)
            #expect(try f.repository.engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_media_assets", values: []) == 1)
            let backup = f.root.appendingPathComponent("corpus.lingrove")
            await f.store.backup(to: backup, scope: saved)
            var options = VocabularyExportConfiguration(); options.images = true
            let package = try await f.store.prepareExport(selections: [.init(entryID: original.id, senseID: original.senses[0].id)], configuration: options, scope: saved)
            #expect(package.images[png.reference.filename] == png.data)
            #expect(await f.store.removeSense(entryID: original.id, senseID: original.senses[0].id, scope: saved))
            #expect(f.store.entries.isEmpty)
            await f.store.restore(from: backup, scope: try f.repository.snapshot())
            #expect(f.store.entries == saved.document.collectedEntries)
            #expect(try f.repository.engine.loadLingroveNotebookReviewEnrollments(workspaceId: saved.workspaceId).isEmpty)
            await f.store.shutdown()
            try f.repository.shutdown()
            let reopened = try MacNotebookRepository(databaseURL: f.repository.databaseURL, mediaDirectoryURL: f.repository.mediaDirectoryURL)
            defer { try? reopened.shutdown() }
            let store = VocabularyStore(repository: reopened); await store.load()
            #expect(store.entries == saved.document.collectedEntries)
            #expect(await store.image(png.reference) == png.data)
            #expect(try reopened.engine.core.scalarInt(sql: "SELECT COUNT(*) FROM pragma_foreign_key_check", values: []) == 0)
            await store.shutdown()
        }
    }

    @Test func oldDraftImportAnkiAndExplanationCallbacksCannotAcquireANewGeneration() async throws {
        try await withFixture { f in
            await f.store.load()
            _ = try await f.store.addEntries([.init(expression: "serendipity", meaning: "a happy discovery")])
            let oldScope = try #require(f.store.operationScope), oldIdentity = f.store.scopeIdentity
            let oldEntry = try #require(f.store.entries.first)
            let anki = AnkiReviewController(settings: AnkiReviewSettings(defaults: f.defaults, credentials: AnkiCredentialStore(service: nil)),
                store: f.store, client: ReviewFakeAnki(), activateAnki: {})
            let oldAnkiSession = AnkiReviewSession(controller: anki, entry: oldEntry, sense: oldEntry.senses[0])
            let importSession = VocabularyWordListImportSession(store: f.store)
            let csv = f.root.appendingPathComponent("words.csv")
            try Data("expression,meaning\nadditional,a new word".utf8).write(to: csv)
            await importSession.load(csv, language: .english)
            for _ in 0..<50 { if !importSession.preparing { break }; try await Task.sleep(for: .milliseconds(10)) }
            let settings = LanguageLearningSettings(defaults: f.defaults)
            let model = LearningModelController(profile: settings.explanation,
                client: OpenAICompatibleAPIClient(session: URLSession(configuration: .ephemeral)), localModelURL: { _ in URL(fileURLWithPath: "/unused-synthetic-model.gguf") })
            defer { model.shutdownSync() }
            let service = LearningExplanationService(settings: settings, model: model, telemetry: LearningRequestTelemetry())
            f.store.connectExplanations(to: service)
            let latePersistence = try #require(service.capturePersistence?())
            let input = LearningExplanationPolicy.input(LearningExplanationPolicy.capture(oldEntry, sense: oldEntry.senses[0], example: nil))
            let record = LearningExplanationRecord(id: UUID(), input: input, language: .english,
                result: .init(meaning: "late", explanation: "old account result"), model: "synthetic", createdAt: Date())
            let target = UUID().uuidString.lowercased()
            let account = CloudLinkedSession(userId: "synthetic-other-owner", workspaceId: target, email: nil,
                configurationMode: .custom, apiBaseUrl: "http://127.0.0.1:19380", authorization: .bearer("unused"))
            try f.repository.engine.switchActiveWorkspace(workspace: .init(workspaceId: target, name: "Other", createdAt: "2026-11-03T00:00:00.000Z", isSelected: true), linkedSession: account)
            f.repository.publishChange(); await f.store.load()
            #expect(f.store.scopeIdentity != oldIdentity && f.store.entries.isEmpty)
            #expect(await importSession.commit() == nil)
            #expect(oldAnkiSession.current == nil)
            let oldAnkiSaved = await oldAnkiSession.save()
            #expect(!oldAnkiSaved)
            #expect(!(await f.store.update(oldEntry, basedOn: oldEntry, scope: oldScope)))
            // Return to the same notebook at the same revision: its new generation must still reject
            // the old sheet/Anki receipt/automatically persisted explanation from before the switch.
            try f.repository.engine.updateCloudSettings(cloudState: .disconnected, linkedUserId: nil, linkedWorkspaceId: nil,
                activeWorkspaceId: oldScope.workspaceId, linkedEmail: nil)
            f.repository.publishChange(); await f.store.load()
            let returned = try f.repository.snapshot()
            #expect(returned.generation != oldScope.generation && returned.document == oldScope.document)
            #expect(!(await f.store.update(oldEntry, basedOn: oldEntry, scope: oldScope)))
            latePersistence(record)
            for _ in 0..<10 { await Task.yield() }
            #expect(try f.repository.snapshot().document == returned.document)
            #expect(service.cached(input) == nil)
            #expect(!f.store.matches(oldScope))
        }
    }

    @Test func CLIAdmissionReceiptsScopeAndFailureModeRemainExplicit() async throws {
        try await withFixture { f in
            await f.store.load()
            let request = try Self.request(["version": 1, "idempotencyKey": "new-v1", "operations": [["add": ["expression": "serendipity", "language": "en", "kind": "word", "meaning": "discovery"]]]])
            let first = await f.store.executeCLI(request)
            #expect(first.ok && f.store.entries.count == 1)
            let saved = try f.repository.snapshot()
            #expect((await f.store.executeCLI(request)).ok)
            #expect(try f.repository.snapshot() == saved)
            let read = await f.store.executeCLI(.init(command: .status))
            guard case let .object(status)? = read.result else { Issue.record("Expected status object"); return }
            let scope = try #require(status["notebookScope"])
            let entry = try #require(f.store.entries.first)
            var edit = try Self.request(["version": 1, "idempotencyKey": "edit-no-scope", "operations": [["update": ["entryID": entry.id.uuidString, "senseID": entry.senses[0].id.uuidString, "expectedRevision": saved.revision, "note": "authored"]]]])
            #expect(!(await f.store.executeCLI(edit)).ok)
            edit.batch?.notebookScope = try JSONDecoder().decode(CLINotebookScope.self, from: JSONEncoder().encode(scope))
            #expect((await f.store.executeCLI(edit)).ok)
            #expect(f.store.entries[0].senses[0].note == "authored")
            let existingCapture = try Self.request(["version": 2, "idempotencyKey": "existing-capture-no-scope",
                "operations": [["capture": ["defaults": ["language": "en"], "entries": [["expression": entry.expression,
                    "senses": [["id": entry.senses[0].id.uuidString, "tags": ["must-not-write"]]]]]]]]])
            let refused = await f.store.executeCLI(existingCapture)
            #expect(!refused.ok && refused.error?.code == .conflict)
            #expect(!f.store.entries[0].senses[0].tags.contains("must-not-write"))
            #expect(CLICaptureContract.schema["allOf"] != nil)
            let largeEntries: [[String: Any]] = (0..<9).map { index in
                ["expression": "synthetic-" + String(index) + String(repeating: "x", count: 31_980),
                 "senses": [["meaning": "bounded acknowledgement"]]]
            }
            let large = try Self.request(["version": 2, "idempotencyKey": "bounded-large-receipt",
                "operations": [["capture": ["defaults": ["language": "en"], "entries": largeEntries]]]])
            let acknowledgement = await f.store.executeCLI(large)
            #expect(acknowledgement.ok)
            #expect(try JSONEncoder().encode(acknowledgement).count > 256 * 1_024)
            #expect((await f.store.executeCLI(large)).ok)
            let corruptURL = f.root.appendingPathComponent("corrupt.sqlite")
            let originalBytes = Data("synthetic-corrupt-database".utf8)
            try originalBytes.write(to: corruptURL)
            let unavailable: VocabularyStore
            do {
                _ = try MacNotebookRepository(databaseURL: corruptURL, mediaDirectoryURL: f.root.appendingPathComponent("corrupt-media"))
                Issue.record("Corrupt database must fail rather than become an empty notebook")
                return
            } catch { unavailable = VocabularyStore.unavailable(error) }
            #expect(try Data(contentsOf: corruptURL) == originalBytes)
            await unavailable.save(.init(expression: "blocked", dictionaryForm: "blocked", language: .english, kind: .word))
            #expect(!unavailable.isAvailable && !unavailable.isLoaded && unavailable.entries.isEmpty && unavailable.errorMessage != nil)
            #expect(!(await unavailable.executeCLI(request)).ok)
        }
    }

    @Test func uncollectedMaterialCannotReceiveANewAutomaticExplanation() async throws {
        try await withFixture { f in
            await f.store.load()
            let sentence = "We found serendipity on the journey."
            let occurrence = try #require(VocabularyPolicy.example(text: sentence,
                ranges: [(sentence as NSString).range(of: "serendipity")], language: .english))
            let capture = VocabularyCapture(expression: "serendipity", dictionaryForm: "serendipity", language: .english,
                kind: .word, example: occurrence)
            await f.store.save(capture)
            let input = LearningExplanationPolicy.input(capture)
            let first = LearningExplanationRecord(id: UUID(), input: input, language: .english,
                result: .init(meaning: "a discovery", explanation: "saved annotation"), model: "synthetic", createdAt: Date())
            await f.store.saveExplanation(first)
            #expect(try f.repository.snapshot().document.entries[0].explanations?.contains(first) == true)
            await f.store.remove(capture)
            let removed = try f.repository.snapshot()
            #expect(removed.document.collectedEntries.isEmpty && !removed.document.catalog.isEmpty)
            let later = LearningExplanationRecord(id: UUID(), input: input, language: .english,
                result: .init(meaning: "new temporary result", explanation: "must stay temporary"), model: "synthetic", createdAt: Date())
            await f.store.saveExplanation(later, scope: removed)
            #expect(try f.repository.snapshot() == removed)
        }
    }

    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_UI_CORPUS_ACCEPTANCE"] == "1"))
    func nativeCreateCancelSaveEditAndReopenJourney() async throws {
        try await withFixture { f in
            await f.store.load()
            let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/mac-w2-c/native")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let done = output.appendingPathComponent("done")
            try? FileManager.default.removeItem(at: done)
            let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: f.defaults))
            let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 1100, height: 780),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "C Corpus Validation"
            let host = NSHostingView(rootView: VocabularyNotebookView(store: f.store, speech: speech, preferences: f.defaults))
            window.contentView = host
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            defer { window.close() }
            try JSONSerialization.data(withJSONObject: ["window": window.title, "pid": ProcessInfo.processInfo.processIdentifier,
                "database": f.repository.databaseURL.path, "done": done.path], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("ready.json"))
            for _ in 0..<480 {
                if FileManager.default.fileExists(atPath: done.path) { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            #expect(FileManager.default.fileExists(atPath: done.path))
            #expect(f.store.entries.count == 1)
            let entry = try #require(f.store.entries.first)
            #expect(entry.expression == "serendipity" && entry.senses[0].meaning == "a happy discovery")
            #expect(entry.senses[0].note == "Mac native edit")
            let saved = try f.repository.snapshot()
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("saved-native.png"))
            window.close()
            await f.store.shutdown()
            try f.repository.shutdown()
            let reopened = try MacNotebookRepository(databaseURL: f.repository.databaseURL, mediaDirectoryURL: f.repository.mediaDirectoryURL)
            defer { try? reopened.shutdown() }
            #expect(try reopened.snapshot().document.collectedEntries == saved.document.collectedEntries)
            try JSONSerialization.data(withJSONObject: ["entries": saved.document.collectedEntries.count,
                "expression": entry.expression, "meaning": entry.senses[0].meaning, "note": entry.senses[0].note,
                "revision": saved.revision, "reopened": true], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("stored-proof.json"))
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await body(fixture) } catch { await fixture.cleanUp(); throw error }
        await fixture.cleanUp()
    }

    private static func request(_ batch: [String: Any]) throws -> CLIRequest {
        CLIRequest(command: .apply, batch: try JSONDecoder().decode(CLIBatch.self, from: JSONSerialization.data(withJSONObject: batch)))
    }

    @MainActor private final class Fixture {
        let root: URL
        let repository: MacNotebookRepository
        let store: VocabularyStore
        let defaults: UserDefaults
        private let suite: String
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-corpus-" + UUID().uuidString)
            suite = "MacCorpusFixture." + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: suite))
            repository = try MacNotebookRepository(databaseURL: root.appendingPathComponent("data.sqlite"), mediaDirectoryURL: root.appendingPathComponent("media"))
            store = VocabularyStore(repository: repository)
        }
        func cleanUp() async {
            await store.shutdown()
            try? repository.shutdown(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
