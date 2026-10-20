import AppKit
import Combine
import SwiftUI
import Testing
import Vision
@testable import Cotabby

/// Production roots exercise default sense presentation and the notebook's live reference area.
/// Fixtures use isolated archives and explicit fake providers; no real model or user text is read.
@Suite(.serialized)
@MainActor
struct LearningContextualLookupViewTests {
    @Test(arguments: [LearningExplanationContext.sentence, .fragment, .none])
    func queriedUnitShowsTheAppropriateSenseBeforeAnyDictionaryRequest(_ scope: LearningExplanationContext) async throws {
        let provider = LookupViewDictionary(), service = LookupViewExplainer()
        let session = LearningDictionarySession(provider: provider, explanationService: service)
        var capture = capture()
        if scope == .none { capture.example = nil } else if scope == .fragment { capture.example?.completeness = .fragment }
        let ranges = capture.example?.ranges.map(\.nsRange) ?? [NSRange(location: 0, length: capture.expression.utf16.count)]
        let unit = LearningUnit(id: 0, surface: capture.expression, query: capture.dictionaryForm, kind: .pattern,
            ranges: ranges, words: [])
        let native = ProcessInfo.processInfo.environment["COTABBY_UI_CONTEXT_REVIEW"] == "1"
        let window = NSPanel(contentRect: .init(x: 100, y: 100, width: 340, height: 400),
            styleMask: native ? [.titled] : [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if native { window.level = .floating }
        let host = NSHostingView(rootView: LearningDictionaryCard(session: session, close: {}, sizeChanged: { _ in }, lookup: { _, _ in }))
        window.contentView = host; window.appearance = NSAppearance(named: .aqua); window.orderFrontRegardless()
        defer { session.close(); window.close() }
        session.open(unit, documentID: UUID(), language: .english, vocabularyCapture: capture)
        try await settle(host, window)
        let text = try snapshot(host, name: "contextual-query-" + scope.rawValue)
        #expect(session.page == .contextual && session.explanation.record?.result.meaning == "Keep someone informed")
        #expect(text.contains("Keep someone informed"))
        #expect(session.explanation.input?.contextKind == scope)
        if scope == .none {
            #expect(!text.contains("Please keep me posted"))
            #expect(!text.contains(String(localized: "Contextual meaning", table: "Learning")))
        } else { #expect(text.contains("Please keep me posted")) }
        #expect(!text.contains("Detailed construction") && !text.contains("LIVE DICTIONARY"))
        #expect(await provider.calls == 0)
        if native, scope == .sentence {
            window.title = "Lingrove contextual lookup acceptance"
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(45))
        }
    }

    @Test func notebookShowsSavedSensesBesideExamplesAndQueriesDictionaryOnDemand() async throws {
        let store = VocabularyStore(archive: VocabularyArchive(url: nil))
        let capture = capture()
        await store.save(capture)
        let input = LearningExplanationPolicy.input(capture)
        await store.saveExplanation(LookupViewExplainer.record(input))
        let entry = try #require(store.entries.first)
        let service = LookupViewExplainer(), provider = LookupViewDictionary()
        let learning = VocabularyNotebookSession(service: service, provider: provider)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 940, height: 640),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VocabularyNotebookView(store: store, speech: speech, selectedID: entry.id, learning: learning)
            .background(Color.white).environment(\.colorScheme, .light))
        window.contentView = host; window.appearance = NSAppearance(named: .aqua); window.orderFrontRegardless()
        defer { learning.cancel(); window.close() }
        try await settle(host, window, resize: false)
        let text = try snapshot(host, name: "contextual-notebook")
        #expect(text.contains("Keep someone informed") && text.contains("Please keep me posted"))
        #expect(await provider.calls == 0)
        #expect(service.generations == 0, "Browsing a saved explanation must not run the model")
        if ProcessInfo.processInfo.environment["COTABBY_UI_CONTEXT_REVIEW"] == "1" {
            window.title = "Lingrove notebook lookup acceptance"
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .seconds(45))
        }
        learning.showDictionary(entry)
        try await settle(host, window, resize: false)
        #expect(await provider.calls > 0)
    }

    private func capture() -> VocabularyCapture {
        let sentence = "Please keep me posted on the progress."
        var example = VocabularyPolicy.example(text: sentence,
            ranges: [(sentence as NSString).range(of: "keep me posted")], language: .english)
        example?.translation = "请随时告诉我最新进展。"
        return .init(expression: "keep someone posted", dictionaryForm: "keep someone posted", language: .english,
            kind: .pattern, example: example)
    }
    private func settle<Content: View>(_ host: NSHostingView<Content>, _ window: NSWindow, resize: Bool = true) async throws {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            if resize { window.setContentSize(host.fittingSize) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private func snapshot<Content: View>(_ host: NSHostingView<Content>, name: String) throws -> String {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: path).appendingPathComponent(name + ".png"))
        }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

private actor LookupViewDictionary: LearningDictionaryProviding {
    var calls = 0
    func lookup(_ query: String, language: LearningLanguage, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        calls += 1
        return .systemText(source == .system ? "LIVE DICTIONARY SYSTEM" : "LIVE DICTIONARY BUILTIN")
    }
}

@MainActor private final class LookupViewExplainer: LearningExplanationGenerating {
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    var language: LearningLanguage { .english }
    var isConfigured: Bool { true }
    var generations = 0
    func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        generations += 1
        return Self.record(input)
    }
    static func record(_ input: LearningExplanationInput) -> LearningExplanationRecord {
        .init(id: UUID(), input: input, language: .english,
            result: .init(meaning: "Keep someone informed", explanation: "Detailed construction and usage of this expression."),
            model: "fixture", createdAt: Date())
    }
    func recordDisplay(requestID: String) {}
}
