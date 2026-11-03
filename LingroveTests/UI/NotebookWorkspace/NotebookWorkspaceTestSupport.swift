import AppKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import SwiftUI
import Testing
@testable import Lingrove

/// A private notebook branch uses real SQLite and production presentation owners. The test owns
/// every preference/data path and never starts global input, authentication, downloads or sync.
@MainActor
final class NotebookWorkspaceFixture {
    let directory: URL
    let suite = "lingrove.workspace.synthetic." + UUID().uuidString
    let defaults: UserDefaults
    let repository: MacNotebookRepository
    let store: VocabularyStore
    let account: AccountSessionService
    let sync: MacNotebookSyncController
    let anki: AnkiReviewController
    let review: BuiltInReviewController
    let speech: LearningSpeechController
    let search: VocabularySearchController
    let window: VocabularyWindowController
    let progress = NotebookWorkspaceProgressProbe()
    private(set) var settings: SettingsCoordinator?
    private(set) var settingsWindow: NSWindow?

    init(usesRealProgress: Bool = false, accountService: AccountSessionService? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-workspace-" + UUID().uuidString)
        defaults = try workspaceRequire(UserDefaults(suiteName: suite))
        repository = try .init(databaseURL: directory.appendingPathComponent("primary.sqlite"),
            mediaDirectoryURL: directory.appendingPathComponent("media"))
        account = accountService ?? .init(client: AccountAPIClient(), credentials: KeychainAccountCredentialStore(bundleIdentifier: suite),
            settings: AccountConfigurationStore(defaults: defaults))
        sync = .init(repository: repository, account: account, consentStore: MacNotebookSyncConsentStore(defaults: defaults))
        store = VocabularyStore(repository: repository)
        speech = .init(settings: LearningSpeechSettings(defaults: defaults),
            modelDirectoryURL: directory.appendingPathComponent("speech-models"))
        search = .init(store: store, directoryURL: directory.appendingPathComponent("search-models"), cacheURL: nil)
        review = .init(repository: repository, speech: speech)
        anki = .init(settings: AnkiReviewSettings(defaults: defaults, credentials: AnkiCredentialStore(service: nil)),
            store: store, client: ReviewFakeAnki(), speech: speech, activateAnki: {})
        let probe = progress
        let progressRepository = repository
        window = .init(store: store, speech: speech, dictionaryProvider: LearningLexiconService(resourceURL: nil),
            learningSettings: LanguageLearningSettings(defaults: defaults), review: anki, search: search, preferences: defaults,
            builtInReview: review, account: account, sync: sync, progressContent: { active in
                probe.visibility.append(active)
                if usesRealProgress {
                    return AnyView(NotebookProgressView(repository: progressRepository, isActive: active))
                }
                return AnyView(Text("Injected Progress fixture").frame(maxWidth: .infinity, maxHeight: .infinity))
            })
        let window = window
        review.onShow = { [weak window] in window?.showReview(selection: $0) }
        review.onOpenSource = { [weak window] in window?.show(selectedID: $0.entryID, senseID: $0.senseID) }
        store.onRequestBuiltInReview = { [weak review] in review?.show(selection: $0) }
        self.window.onShowSettings = { [weak self] in self?.openSettings(account: false) }
        self.window.onShowAccount = { [weak self] in self?.openSettings(account: true) }
    }

    @discardableResult
    func seed(_ expression: String = "harbor") async throws -> VocabularySelection {
        await store.save(.init(expression: expression, dictionaryForm: expression, language: .english,
            kind: .word, meaning: "a sheltered place for boats", meaningLanguage: .english))
        let entry = try workspaceRequire(store.entries.first { $0.expression == expression })
        return .init(entryID: entry.id, senseID: try workspaceRequire(entry.senses.first).id)
    }

    func cleanUp() async {
        // End test-owned sheets explicitly; this is teardown, never a production navigation path.
        if let sheet = window.window?.attachedSheet { window.window?.endSheet(sheet) }
        review.session.draft = nil
        window.close()
        settingsWindow?.close()
        await review.shutdownAfterDraining()
        search.suspend()
        speech.stop()
        sync.shutdown()
        account.shutdown()
        await store.shutdown()
        try? repository.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func openSettings(account: Bool) {
        if settings == nil { settings = makeSettings() }
        let previous = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        if account { settings?.showAccount() } else { settings?.showSettings() }
        let windows = NSApplication.shared.windows
        // The existing SwiftUI navigation can supply the active pane's window title. Identify
        // the newly created production host by native identity/type rather than assuming copy.
        if settingsWindow == nil {
            settingsWindow = windows.first {
                !previous.contains(ObjectIdentifier($0)) && $0.contentViewController is NSHostingController<AnyView>
            }
        }
        if let output = ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_EVIDENCE_DIR"] {
            let record: [[String: Any]] = windows.map { value in
                ["windowNumber": value.windowNumber, "title": value.title, "isVisible": value.isVisible,
                 "isNew": !previous.contains(ObjectIdentifier(value)),
                 "controller": value.contentViewController.map { String(reflecting: type(of: $0)) } ?? "none",
                 "identifiedSettings": value === settingsWindow]
            }
            let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: output).appendingPathComponent(account
                ? "settings-account-windows.json" : "settings-open-windows.json"))
        }
    }

    /// Only presentation dependencies for the existing coordinator are assembled here. Nothing
    /// starts a model, updater or service, and all durable settings are the fixture's own suite.
    private func makeSettings() -> SettingsCoordinator {
        let permissions = PermissionManager()
        let suggestion = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        let downloads = ModelDownloadManager(runtimeDirectoryURL: directory.appendingPathComponent("models"))
        return SettingsCoordinator(accountService: account, notebookSync: sync, speech: speech, review: anki, vocabularySearch: search,
            appUpdateManager: AppUpdateManager(), permissionManager: permissions,
            permissionGuidanceController: PermissionGuidanceController(permissionManager: permissions),
            suggestionSettings: suggestion,
            interfaceLanguageSettings: InterfaceLanguageSettingsModel(store: InterfaceLanguageSettingsStore(
                userDefaults: defaults, bundleIdentifier: suite)),
            openAICompatibleConnectionModel: OpenAICompatibleConnectionModel(client: OpenAICompatibleAPIClient()),
            foundationModelAvailabilityService: FoundationModelAvailabilityService(provider: NotebookWorkspaceAvailability()),
            runtimeModel: RuntimeBootstrapModel(runtimeManager: LlamaRuntimeManager(), userDefaults: defaults),
            modelDownloadManager: downloads, huggingFaceSearchService: HuggingFaceSearchService(),
            performanceMetricsStore: PerformanceMetricsStore(userDefaults: defaults),
            qualityMetricsStore: SuggestionQualityMetricsStore(userDefaults: defaults), systemMetricsStore: SystemMetricsStore(),
            onShowWelcome: {}, clearEmojiHistory: {},
            typingHistoryStore: TypingHistoryStore(userDefaults: defaults, loadsArchive: false))
    }
}

/// An injected test destination only records the container's active flag; it never stands in for
/// NotebookProgressView or supplies invented statistics. The real view is integrated by root.
@MainActor
final class NotebookWorkspaceProgressProbe {
    var visibility: [Bool] = []
}

@MainActor
private final class NotebookWorkspaceAvailability: FoundationModelAvailabilityProviding {
    var currentState: FoundationModelAvailabilityState { .unavailable("Synthetic validation host") }
    func refresh() -> FoundationModelAvailabilityState { currentState }
    func observe(onChange: @escaping @MainActor (FoundationModelAvailabilityState) -> Void) -> Task<Void, Never>? { nil }
}

@MainActor
func workspaceEventually(_ predicate: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while try !predicate() {
        try workspaceRequire(ContinuousClock.now < deadline, "The native fixture did not reach the expected state")
        try await Task.sleep(for: .milliseconds(30))
    }
}

@MainActor
func captureWorkspace(_ window: NSWindow, name: String) async throws {
    guard let path = ProcessInfo.processInfo.environment["LINGROVE_WORKSPACE_EVIDENCE_DIR"] else { return }
    try await Task.sleep(for: .milliseconds(180))
    let view = try workspaceRequire(window.contentView)
    view.layoutSubtreeIfNeeded()
    let bitmap = try workspaceRequire(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try workspaceRequire(bitmap.representation(using: .png, properties: [:]))
    try workspaceRequire(data.count > 1_000)
    let output = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try data.write(to: output.appendingPathComponent(name + ".png"))
    try JSONSerialization.data(withJSONObject: ["title": window.title, "width": view.bounds.width,
        "height": view.bounds.height, "toolbarItems": window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []],
        options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name + "-window.json"))
}

/// Swift Testing captures every operand of a macro, even a passing one. Reflecting a fixture
/// after it owns Settings recursively visits the entire service/view graph. Evaluate the real
/// expression at the call site, then capture only this Bool while keeping its source location.
nonisolated func workspaceExpect(_ passed: Bool, _ comment: Comment? = nil,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(passed, comment, sourceLocation: sourceLocation)
}

nonisolated func workspaceRequire<Value>(_ value: Value?, _ comment: Comment? = nil,
                                        sourceLocation: SourceLocation = #_sourceLocation) throws -> Value {
    guard let value else {
        Issue.record(comment ?? "Required workspace fixture value is missing", sourceLocation: sourceLocation)
        throw NotebookWorkspaceMissingValue()
    }
    return value
}

nonisolated func workspaceRequire(_ passed: Bool, _ comment: Comment? = nil,
                                 sourceLocation: SourceLocation = #_sourceLocation) throws {
    guard passed else {
        Issue.record(comment ?? "Required workspace test condition failed", sourceLocation: sourceLocation)
        throw NotebookWorkspaceMissingValue()
    }
}

private struct NotebookWorkspaceMissingValue: Error {}
