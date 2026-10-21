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
    @Test(arguments: [false, true])
    func generationIconCanStopRetryRegenerateAndOpenConfiguration(_ dark: Bool) async throws {
        let input = LearningExplanationInput(target: "know", dictionaryForm: "know", language: .english, kind: .word,
            context: "Let me know.", ranges: [.init(NSRange(location: 7, length: 4))])
        let service = CardExplainer()
        let active = LearningExplanationSession(service: service)
        active.setTarget(input)
        var configurations = 0, preparations = 0
        let host = NSHostingView(rootView: LearningExplanationButton(session: active,
            prepare: { preparations += 1 }, configure: { configurations += 1 }).padding(10))
        let nativeReview = ProcessInfo.processInfo.environment["COTABBY_UI_STATUS_REVIEW"] == "1"
        let window = NSPanel(contentRect: .init(x: 100, y: 100, width: 42, height: 42),
            styleMask: nativeReview ? [.titled] : [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { active.cancel(); service.finishPending(); window.close() }
        window.orderFrontRegardless()
        func settle() async throws {
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        try await settle()
        let size = host.fittingSize
        func capture(_ state: String) async throws {
            try await settle()
            #expect(host.fittingSize == size, "Status feedback must not move the neighboring toolbar actions")
            if let path = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] {
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let name = "explanation-\(state)-\(dark ? "dark" : "light").png"
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
            }
        }
        try await capture("idle")
        try clickCenter(host, in: window)
        try await settle()
        let saved = try #require(active.record)
        try await capture("ready")
        service.delays = true
        try clickCenter(host, in: window)
        try await capture("generating")
        #expect(active.isGenerating && service.pending != nil && active.record == saved)
        if nativeReview, !dark {
            window.title = "Lingrove AI status acceptance"
            try await Task.sleep(for: .seconds(45))
        }
        try clickCenter(host, in: window, offset: 10)
        #expect(!active.isGenerating && active.record == saved && preparations == 2,
            "The progress ring must stop work without expanding the card")
        service.finishPending()
        try await settle()
        #expect(active.record == saved, "A cancelled reply must not replace the previous explanation")
        try clickCenter(host, in: window)
        try await settle()
        service.finishPending(error: NSError(domain: "fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Explanation failed."]))
        try await capture("failed")
        #expect(active.error == "Explanation failed." && active.record == saved && !active.isGenerating)
        try clickCenter(host, in: window)
        try await settle()
        #expect(active.isGenerating && active.error == nil && active.record == saved)
        service.finishPending()
        try await settle()
        #expect(active.record != nil && active.record != saved && active.error == nil && !active.isGenerating)
        #expect(service.refreshes == [false, true, true, true])
        service.isConfigured = false
        try await capture("unconfigured")
        try clickCenter(host, in: window)
        try await settle()
        #expect(configurations == 1 && service.refreshes.count == 4)
    }

    private func clickCenter(_ host: NSView, in window: NSWindow, offset: CGFloat = 0) throws {
        let point = host.convert(CGPoint(x: host.bounds.midX + offset, y: host.bounds.midY), to: nil)
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
        let changed = PassthroughSubject<Void, Never>()
        var changes: AnyPublisher<Void, Never> { changed.eraseToAnyPublisher() }
        var language: LearningLanguage { .english }
        var isConfigured = true { didSet { changed.send() } }
        var refreshes: [Bool] = []
        var delays = false
        var pending: (LearningExplanationInput, CheckedContinuation<LearningExplanationRecord, any Error>)?
        func generate(_ input: LearningExplanationInput, requestID: String, refresh: Bool) async throws -> LearningExplanationRecord {
            refreshes.append(refresh)
            if delays { return try await withCheckedThrowingContinuation { pending = (input, $0) } }
            return record(for: input)
        }
        func finishPending(error: (any Error)? = nil) {
            guard let (input, continuation) = pending else { return }
            pending = nil
            if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: record(for: input)) }
        }
        private func record(for input: LearningExplanationInput) -> LearningExplanationRecord {
            .init(id: UUID(), input: input, language: language,
                result: .init(meaning: "Be informed", explanation: "A contextual explanation."), model: "fixture", createdAt: Date())
        }
        func recordDisplay(requestID: String) {}
    }
}
