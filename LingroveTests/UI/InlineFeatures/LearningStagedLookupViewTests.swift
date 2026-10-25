import AppKit
import Combine
import SwiftUI
import Testing
import Vision
@testable import Lingrove

/// The production dictionary card owns the visible staged-lookup experience. A local fake keeps
/// this test focused on which model stage the UI requests and what each stage paints.
@Suite(.serialized)
@MainActor
struct LearningStagedLookupViewTests {
    @Test func lookupShowsTheBasicPairAndLoadsDetailsOnlyWhenExpanded() async throws {
        let service = StagedLookupViewService()
        let session = LearningDictionarySession(provider: StagedLookupViewDictionary(), explanationService: service)
        let capture = makeCapture()
        let unit = unit(for: capture)
        let defaultsSuite = "StagedLookupView-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let vocabulary = VocabularyStore(archive: VocabularyArchive(url: nil))
        let silentSpeech = StagedLookupViewSilentSpeech()
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults),
            provider: silentSpeech)
        let window = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 340, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        let host = NSHostingView(rootView: LearningDictionaryCard(session: session, close: {},
            sizeChanged: { _ in }, lookup: { _, _ in }, speech: speech, vocabulary: vocabulary))
        window.contentView = host
        defer { speech.stop(); session.close(); window.close() }

        window.orderFrontRegardless()
        session.open(unit, documentID: UUID(), language: .english,
            vocabularyCapture: capture, translationLanguage: .chinese)
        await wait { session.explanation.lookupRecord != nil }
        try await settle(host, window)

        let initial = try snapshot(host, name: "staged-lookup-initial")
        #expect(initial.contains("Keep someone informed"), "The first lookup result should show its meaning")
        #expect(initial.contains("请随时告诉我最新进展"), "The same result should show its sentence translation")
        #expect(!initial.contains("Detailed usage for this expression"))
        #expect(!initial.contains("Words in this expression") && !initial.contains("AI explanation"))
        // NSHostingView does not expose SwiftUI's virtual button nodes to in-process AX queries.
        // Send real mouse events to the measured header hit targets and verify their effects.
        try clickHeaderAction(trailingOffset: 81, in: host, window: window)
        await wait { vocabulary.contains(capture) }
        #expect(vocabulary.entries.count == 1, "Activating the fish-tail action should save this captured usage")

        try clickHeaderAction(trailingOffset: 53, in: host, window: window)
        await wait { !silentSpeech.spokenTexts.isEmpty }
        #expect(silentSpeech.spokenTexts == [capture.expression],
            "The visible reading action should send the expression to the silent speech provider")
        #expect(service.lookupCalls == 1)
        #expect(service.detailCalls == 0, "Opening a card must not pay for detailed usage")
        #expect(service.legacyCalls == 0, "Staged lookup should use its pair and detail requests")

        let detailsLabel = String(localized: "Details", table: "Learning")
        try clickDisclosure(detailsLabel, host: host, window: window)
        await wait { service.detailCalls == 1 && session.explanation.record != nil }
        try await settle(host, window)
        let expanded = try snapshot(host, name: "staged-lookup-details-expanded")
        #expect(expanded.contains("Detailed usage for this expression"))
        #expect(service.lookupCalls == 1 && service.detailCalls == 1)

        try clickDisclosure(detailsLabel, host: host, window: window)
        try await settle(host, window)
        #expect(!(try snapshot(host, name: "staged-lookup-details-collapsed"))
            .contains("Detailed usage for this expression"))
        try clickDisclosure(detailsLabel, host: host, window: window)
        try await settle(host, window)
        #expect((try snapshot(host, name: "staged-lookup-details-reopened"))
            .contains("Detailed usage for this expression"))
        #expect(service.detailCalls == 1, "Collapsing and reopening completed details must reuse the result")
    }

    @Test func standaloneReadingLookupOwnsItsWindowAndLetsEscapeReachTheReadingOwner() async throws {
        let screen = try #require(NSScreen.main?.visibleFrame)
        let anchor = CGRect(x: screen.midX, y: screen.midY, width: 2, height: 18)
        var hitWindowNumber = 0
        let panel = LearningSentencePanel(dictionaryProvider: StagedLookupViewDictionary(),
            observesMouseEvents: false, windowAtPoint: { _ in hitWindowNumber })
        defer { panel.hide() }
        var dismissals = 0
        panel.showLookup(.init(id: UUID(), capture: makeCapture(), translationLanguage: .chinese, anchor: anchor),
            validate: { true }, dismiss: { dismissals += 1; panel.hide() })

        await wait { panel.isVisible }
        let window = try #require(NSApp.windows.first { panel.owns($0) && $0.parent == nil && $0.isVisible })
        let point = CGPoint(x: window.frame.midX, y: window.frame.midY)
        hitWindowNumber = window.windowNumber
        #expect(panel.owns(window), "The reading panel must own the standalone dictionary card")
        #expect(window.contentView is NSHostingView<LearningDictionaryCard>,
            "Reading should present the existing dictionary card as its standalone surface")
        #expect(panel.containsGlobalInteraction(at: point), "Clicks inside the card belong to the learning UI")

        // A standalone card has no sentence or component-word layer to dismiss. Returning false
        // lets LearningReadingCoordinator's next Escape branch dismiss the lookup itself.
        #expect(!panel.dismissDetail())
        #expect(panel.isVisible && dismissals == 0)
        panel.dismissForGlobalClick(at: point)
        #expect(panel.isVisible && dismissals == 0, "An inside click must not retire the lookup receipt")
        panel.dismissForOutsideClick(in: nil)
        #expect(!panel.isVisible && dismissals == 1)
    }

    private func makeCapture() -> VocabularyCapture {
        let sentence = "Please keep me posted on the progress."
        let range = (sentence as NSString).range(of: "keep me posted")
        var example = VocabularyPolicy.example(text: sentence, ranges: [range], language: .english)
        example?.translation = "原来的翻译不应覆盖本次查词结果。"
        example?.translationLanguage = .chinese
        return .init(expression: "keep me posted", dictionaryForm: "keep me posted", language: .english,
            kind: .expression, example: example)
    }

    private func unit(for capture: VocabularyCapture) -> LearningUnit {
        let example = capture.example
        let ranges = example?.ranges.map(\.nsRange) ?? [NSRange(location: 0, length: capture.expression.utf16.count)]
        return .init(id: 0, surface: capture.expression, query: capture.dictionaryForm,
            kind: .expression, ranges: ranges, words: [])
    }

    private func wait(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate(), "Timed out waiting for the staged lookup UI")
    }

    private func settle<Content: View>(_ host: NSHostingView<Content>, _ window: NSWindow) async throws {
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            window.setContentSize(host.fittingSize)
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func clickDisclosure<Content: View>(
        _ label: String, host: NSHostingView<Content>, window: NSWindow
    ) throws {
        var point = try textPosition(label, in: host)
        // DisclosureGroup's native hit target begins at the triangle just before its label.
        point.x -= 8
        let location = host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            window.sendEvent(event)
        }
    }

    private func textPosition<Content: View>(_ text: String, in host: NSHostingView<Content>) throws -> CGPoint {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
            ? ["zh-Hans", "en-US"] : ["en-US", "zh-Hans"]
        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
        for observation in request.results ?? [] {
            guard let value = observation.topCandidates(1).first,
                  let range = value.string.range(of: text),
                  let box = try value.boundingBox(for: range) else { continue }
            return CGPoint(x: box.boundingBox.minX * host.bounds.width,
                y: (host.isFlipped ? 1 - box.boundingBox.midY : box.boundingBox.midY) * host.bounds.height)
        }
        throw NSError(domain: "StagedLookupViewFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing label: " + text])
    }

    private func snapshot<Content: View>(_ host: NSHostingView<Content>, name: String) throws -> String {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("build/reading-contextual-lookup/renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))

        let image = try #require(bitmap.cgImage)
        let preferredLanguages: [[String]] = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
            ? [["zh-Hans", "en-US"], ["en-US", "zh-Hans"]]
            : [["en-US", "zh-Hans"], ["zh-Hans", "en-US"]]
        // Vision's first recognition language can dominate mixed-script output. Run both orders
        // so the English labels and Chinese sentence translation are independently observable.
        var recognizedLines: [String] = []
        for languages in preferredLanguages {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            try VNImageRequestHandler(cgImage: image).perform([request])
            recognizedLines.append(contentsOf: (request.results ?? []).compactMap { $0.topCandidates(1).first?.string })
        }
        return recognizedLines.joined(separator: " ")
    }

    /// Dictionary cards use 12pt outer padding and a 22pt header. Trailing icon centers are
    /// stable within that row: close at 23pt, speaker near 53pt, and favorite near 81pt.
    private func clickHeaderAction(trailingOffset: CGFloat, in host: NSView, window: NSWindow) throws {
        let point = CGPoint(x: host.bounds.width - trailingOffset,
            y: host.isFlipped ? 24 : host.bounds.height - 24)
        let location = host.convert(point, to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        window.sendEvent(down)
        window.sendEvent(up)
    }
}

@MainActor
private final class StagedLookupViewService: LearningLookupGenerating {
    private let changed = PassthroughSubject<Void, Never>()
    var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
    var language: LearningLanguage { .english }
    var isConfigured = true
    private(set) var lookupCalls = 0
    private(set) var detailCalls = 0
    private(set) var legacyCalls = 0

    func lookup(_ input: LearningLookupInput, requestID: String, refresh: Bool) async throws -> LearningLookupRecord {
        lookupCalls += 1
        return .init(input: input, language: .english,
            result: .init(meaning: "Keep someone informed", sentenceTranslation: "请随时告诉我最新进展。"),
            model: "fixture", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func explainLookup(_ record: LearningLookupRecord, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        detailCalls += 1
        return .init(id: UUID(), input: record.input.target, language: record.language,
            result: .init(meaning: record.result.meaning, explanation: "Detailed usage for this expression."),
            model: "fixture", createdAt: Date(timeIntervalSince1970: 1_800_000_001))
    }

    func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
        legacyCalls += 1
        throw LearningFailure.message("The staged lookup must not call the legacy full explanation task.")
    }

    func recordDisplay(requestID: String) {}
}

private actor StagedLookupViewDictionary: LearningDictionaryProviding {
    func lookup(_ query: String, language: LearningLanguage, expression: Bool,
                source: LearningDictionarySource, configuration: LearningDictionaryConfiguration) async throws -> LearningDictionaryResult {
        .notFound
    }
}

@MainActor
private final class StagedLookupViewSilentSpeech: SpeechProviding {
    var eventHandler: (@MainActor @Sendable (SpeechProviderEvent) -> Void)?
    private(set) var spokenTexts: [String] = []

    func refreshVoices() throws -> [SpeechVoice] {
        [.init(id: "fixture", name: "Fixture", language: "en-US", quality: .standard)]
    }

    func speak(_ text: String, voice: SpeechVoice, rateMultiplier: Double, token: SpeechPlaybackToken) throws {
        spokenTexts.append(text)
        eventHandler?(.started(token))
    }

    func stop(token: SpeechPlaybackToken) {}
}
