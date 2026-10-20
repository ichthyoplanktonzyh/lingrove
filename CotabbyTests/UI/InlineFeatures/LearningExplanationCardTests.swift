import AppKit
import Combine
import SwiftUI
import Testing
import Vision
@testable import Cotabby

/// A real SwiftUI host verifies the shared result controls without a model or host editor.
@Suite(.serialized)
@MainActor
struct LearningExplanationCardTests {
    @Test func generationIconCanRegenerateAndOpenConfiguration() async throws {
        let input = LearningExplanationInput(target: "know", dictionaryForm: "know", language: .english, kind: .word,
            context: "Let me know.", ranges: [.init(NSRange(location: 7, length: 4))])
        let service = CardExplainer()
        let active = LearningExplanationSession(service: service)
        active.setTarget(input)
        var configurations = 0
        let host = NSHostingView(rootView: LearningExplanationButton(session: active, configure: { configurations += 1 }).padding(10))
        let window = NSPanel(contentRect: .init(x: 100, y: 100, width: 42, height: 42),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close(); active.cancel() }
        window.orderFrontRegardless()
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        for count in [1, 2] {
            try clickCenter(host, in: window)
            for _ in 0..<100 {
                if service.refreshes.count == count, !active.isGenerating { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(active.record != nil && service.refreshes.count == count)
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(service.refreshes == [false, true])
        service.isConfigured = false
        try clickCenter(host, in: window)
        for _ in 0..<8 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(configurations == 1 && service.refreshes.count == 2)
    }

    private func clickCenter(_ host: NSView, in window: NSWindow) throws {
        let point = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        window.sendEvent(down); window.sendEvent(up)
    }

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
            .environment(\.colorScheme, .light))
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
        request.recognitionLanguages = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
            ? ["zh-Hans", "en-US"] : ["en-US"]
        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        #expect(text.contains("Be informed") && text.contains("tell someone something"))
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        #expect(normalized(text).contains(normalized(String(localized: "Regenerate", table: "Learning"))))
        #expect(normalized(text).contains(normalized(String(localized: "Use as contextual meaning", table: "Learning"))))
        if let path = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)
                .appendingPathComponent("explanation-result.png"))
        }
    }
    private final class CardExplainer: LearningExplanationGenerating {
        var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
        var language: LearningLanguage { .english }
        var isConfigured = true
        var refreshes: [Bool] = []
        func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
            refreshes.append(refresh)
            return .init(id: UUID(), input: input, language: language,
                result: .init(meaning: "Be informed", explanation: "A contextual explanation."), model: "fixture", createdAt: Date())
        }
        func recordDisplay(requestID: String) {}
    }
}
