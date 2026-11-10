import AppKit
import Combine
import Foundation
import LingroveNotebook
import SwiftUI
import Testing
@testable import Lingrove

/// Opt-in, local-only measurement of the real corpus UI against an explicitly supplied backup.
/// The test copies that immutable input before opening any repository. The production window,
/// store, search and review owners then use the copy; no CLI mailbox, sync, global input monitor
/// or real account is started. Before/after runs can therefore share bytes and UI operations.
@Suite(.serialized, .timeLimit(.minutes(30)))
@MainActor
struct VocabularyPerformanceBaselineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINGROVE_CORPUS_BASELINE_INPUT"] != nil))
    func measureRealCorpusWindow() async throws {
        try #require(Bundle.main.object(forInfoDictionaryKey: "LingroveIsolatedValidationHost") as? Bool == true)
        let environment = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: try #require(environment["LINGROVE_CORPUS_BASELINE_INPUT"]))
        let output = URL(fileURLWithPath: try #require(environment["LINGROVE_CORPUS_BASELINE_OUTPUT"]))
        let manifest = try JSONDecoder().decode(CorpusBaselineInput.self, from: Data(contentsOf: input))
        let fixture = try CorpusBaselineFixture(input: manifest, output: output)
        let recorder = CorpusMainLoopRecorder(output: output)
        recorder.start()
        do {
            try await recorder.measure("initial_store_load") { await fixture.store.load() }
            try #require(fixture.store.isLoaded && fixture.store.errorMessage == nil)
            try await recorder.measure("open_corpus_window") {
                fixture.window.show()
                fixture.window.window?.setContentSize(.init(width: 1240, height: 760))
                fixture.window.window?.contentView?.layoutSubtreeIfNeeded()
            }
            let entries = fixture.store.entries
            let metadata: [String: Any] = [
                "pid": ProcessInfo.processInfo.processIdentifier,
                "bundleID": Bundle.main.bundleIdentifier ?? "",
                "entries": entries.count, "senses": entries.reduce(0) { $0 + $1.senses.count },
                "meanings": fixture.store.semantics.nodes.count,
                "categories": fixture.store.classification.categories.count,
                "database": fixture.directory.appendingPathComponent("primary.sqlite").path,
                "inputDatabaseSHA256": manifest.databaseSHA256,
                "sourceCommit": environment["LINGROVE_CORPUS_BASELINE_COMMIT"] ?? "unknown",
                "search": "keyword-only; isolated empty model directory",
                "doneFile": output.appendingPathComponent("done.json").path,
                "heartbeat": "20ms main-runloop timer; gaps measure unavailability, not input-to-frame latency",
                "openedAt": Date().timeIntervalSince1970
            ]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("ready.json"), options: .atomic)
            let done = output.appendingPathComponent("done.json")
            // The computer-use operator owns UI actions. The test only observes its private
            // process and waits for the explicit handoff file, never synthesizing user events.
            let deadline = Date().addingTimeInterval(25 * 60)
            while !FileManager.default.fileExists(atPath: done.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
            recorder.finish()
            try #require(FileManager.default.fileExists(atPath: done.path), "Baseline UI handoff timed out")
            await fixture.close()
        } catch {
            recorder.finish()
            await fixture.close()
            throw error
        }
    }
}

/// Only file locations and a digest cross the opt-in boundary. Corpus text, account information
/// and access tokens are never included in measurement reports or checked-in fixtures.
private struct CorpusBaselineInput: Decodable {
    let database: String
    let media: String
    let sourceDatabase: String
    let databaseSHA256: String
}

/// One test owns this complete UI lifetime. All collaborators borrow the private repository;
/// a closed window preserves state exactly as production does, while test teardown drains it.
@MainActor
private final class CorpusBaselineFixture {
    let directory: URL
    let defaults: UserDefaults
    let repository: MacNotebookRepository
    let store: VocabularyStore
    let speech: LearningSpeechController
    let search: VocabularySearchController
    let review: BuiltInReviewController
    let window: VocabularyWindowController
    private let suite = "lingrove.corpus.baseline." + UUID().uuidString

    init(input: CorpusBaselineInput, output: URL) throws {
        let source = URL(fileURLWithPath: input.database).standardizedFileURL
        let live = URL(fileURLWithPath: input.sourceDatabase).standardizedFileURL
        try #require(source != live && source.pathComponents.contains("Backups"), "Only an explicit backup is admitted")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        directory = output.appendingPathComponent("working-copy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("primary.sqlite"))
        let media = URL(fileURLWithPath: input.media)
        if FileManager.default.fileExists(atPath: media.path) {
            try FileManager.default.copyItem(at: media, to: directory.appendingPathComponent("Media"))
        }
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("entry", forKey: "vocabularyOrganization")
        defaults.set("list", forKey: "vocabularyBrowserMode")
        defaults.set("compact", forKey: "vocabularyListDensity")
        repository = try MacNotebookRepository(databaseURL: directory.appendingPathComponent("primary.sqlite"),
            mediaDirectoryURL: directory.appendingPathComponent("Media"))
        store = VocabularyStore(repository: repository)
        speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults),
            modelDirectoryURL: directory.appendingPathComponent("speech-models"))
        let downloads = ModelDownloadManager(runtimeDirectoryURL: directory.appendingPathComponent("search-models"),
            assetCatalog: [VocabularySearchCatalog.model], taskAssignments: .init(defaults: defaults))
        search = VocabularySearchController(store: store, directoryURL: directory.appendingPathComponent("search-models"),
            cacheURL: nil, downloads: downloads)
        review = BuiltInReviewController(repository: repository, speech: speech)
        let anki = AnkiReviewController(settings: AnkiReviewSettings(defaults: defaults,
            credentials: AnkiCredentialStore(service: nil)), store: store, client: ReviewFakeAnki(),
            speech: speech, activateAnki: {})
        window = VocabularyWindowController(store: store, speech: speech,
            dictionaryProvider: LearningLexiconService(resourceURL: nil),
            learningSettings: LanguageLearningSettings(defaults: defaults), review: anki, search: search,
            preferences: defaults, builtInReview: review)
        let window = window
        review.onShow = { [weak window] in window?.showReview(selection: $0) }
        store.onRequestBuiltInReview = { [weak window] in window?.showReview(selection: $0) }
    }

    func close() async {
        if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) }
        window.close()
        search.suspend(); speech.stop()
        await review.shutdownAfterDraining()
        await store.shutdown()
        try? repository.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A test-owned timer records actual availability of the app's main run loop. Tool round-trip
/// time is deliberately separate: its AX traversal/waits cannot be treated as UI frame latency.
/// Only stalls are streamed during the run; all ticks and operation timings are saved at teardown.
@MainActor
private final class CorpusMainLoopRecorder {
    private struct Tick: Encodable { let start: Double; let end: Double; let gapMs: Double }
    private struct Operation: Encodable { let name: String; let start: Double; let end: Double; let elapsedMs: Double }
    private let output: URL
    private var timer: Timer?
    private var previous = 0.0
    private var ticks: [Tick] = []
    private var operations: [Operation] = []
    private var stalls: FileHandle?

    init(output: URL) { self.output = output }

    func start() {
        let path = output.appendingPathComponent("stalls.jsonl")
        FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        stalls = try? FileHandle(forWritingTo: path)
        previous = Date().timeIntervalSince1970
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        let tick = Tick(start: previous, end: now, gapMs: (now - previous) * 1000)
        previous = now; ticks.append(tick)
        if tick.gapMs >= 100, let data = try? JSONEncoder().encode(tick) {
            try? stalls?.write(contentsOf: data + Data([10]))
        }
    }

    func measure(_ name: String, operation: () async throws -> Void) async throws {
        let start = Date().timeIntervalSince1970
        try await operation()
        let end = Date().timeIntervalSince1970
        operations.append(.init(name: name, start: start, end: end, elapsedMs: (end - start) * 1000))
    }

    func finish() {
        guard timer != nil else { return }
        tick(); timer?.invalidate(); timer = nil
        try? JSONEncoder().encode(ticks).write(to: output.appendingPathComponent("main-loop-ticks.json"), options: .atomic)
        try? JSONEncoder().encode(operations).write(to: output.appendingPathComponent("operations.json"), options: .atomic)
        try? stalls?.close(); stalls = nil
    }
}
