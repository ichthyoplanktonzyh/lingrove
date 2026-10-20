import AppKit
import Combine
import SwiftUI
import Testing
import Vision
@testable import Cotabby

/// A real SwiftUI host verifies the shared result controls without a model or host editor.
@MainActor
struct LearningExplanationCardTests {
    @Test func completeResultPaintsWithAdoptionAndFitsTheExistingCardWidth() async throws {
        let input = LearningExplanationInput(target: "know", dictionaryForm: "know", language: .english, kind: .word,
            context: "Let me know.", ranges: [.init(NSRange(location: 7, length: 4))])
        let record = LearningExplanationRecord(id: UUID(), input: input, language: .english,
            result: .init(meaning: "Be informed", explanation: "Let someone know means to tell someone something."),
            model: "fixture", createdAt: Date())
        let session = LearningExplanationSession(service: CardExplainer())
        session.setTarget(input, saved: record)
        let host = NSHostingView(rootView: LearningExplanationView(session: session, adopt: { _ in })
            .padding(12).frame(width: 340).background(Color.white)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en")))
        let window = NSPanel(contentRect: .init(x: 100, y: 100, width: 340, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: .aqua); window.backgroundColor = .white
        defer { window.close() }
        window.orderFrontRegardless()
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded(); window.setContentSize(host.fittingSize)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(host.fittingSize.width == 340 && host.fittingSize.height < 300)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        #expect(text.contains("Be informed") && text.contains("tell someone something"))
        #expect(text.contains("Regenerate") && text.contains("contextual meaning"))
        if let path = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)
                .appendingPathComponent("explanation-result.png"))
        }
    }
    private final class CardExplainer: LearningExplanationGenerating {
        var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
        var language: LearningLanguage { .english }
        var isConfigured: Bool { true }
        func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
            throw CancellationError()
        }
        func recordDisplay(requestID: String) {}
    }
}
