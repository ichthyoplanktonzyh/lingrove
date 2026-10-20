import AppKit
import SwiftUI
import Testing
import Vision
@testable import Cotabby

/// Renders the production SwiftUI card in a nonactivating AppKit host. Text recognition verifies that
/// details are painted inside the viewport, not merely retained in a presentation value. This
/// catches zero-preference collapse during compact-to-expanded root replacement without a model.
@Suite(.serialized)
@MainActor
struct LearningSentenceCardTests {
    @Test
    func expandedWidthFitsBothTextsAndShrinksWhenTheSameHostShowsAShortSentence() async throws {
        if let expected = ProcessInfo.processInfo.environment["COTABBY_TEST_LANGUAGE"] {
            #expect(Bundle.main.preferredLocalizations.first == expected,
                    "The locale acceptance run must localize the controls, not just change OCR recognition languages")
        }
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 250),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        func card(source: String, target: String, id: UUID = UUID()) -> LearningSentenceCard {
            let presentation = LearningSentencePresentation(id: id, source: source, translation: target,
                sourceLanguage: .chinese, targetLanguage: .english, caret: .zero, isExpanded: true,
                isGenerating: false, message: "", previousTranslation: nil, shortcutLabel: "⌥T",
                unitStage: .ready, canReplace: true)
            return LearningSentenceCard(presentation: presentation, replace: {},
                expand: {}, dismiss: {}, sizeChanged: { _ in })
        }
        let host = NSHostingView(rootView: card(source: "你好。", target: "Hello."))
        window.contentView = host
        window.orderFrontRegardless()
        await settle(host, in: window)
        let shortWidth = host.fittingSize.width
        #expect(shortWidth >= 320 && shortWidth < 480)
        host.rootView = card(source: String(repeating: "字", count: 22), target: "Yes.")
        await settle(host, in: window)
        #expect(host.fittingSize.width > 320 && host.fittingSize.width < 480,
                "The longer original must determine width even when its translation is short")
        host.rootView = card(source: "你好。", target: String(repeating: "A longer complete translation. ", count: 6))
        await settle(host, in: window)
        #expect(host.fittingSize.width == 480)
        host.rootView = card(source: "你好。", target: "Hello.")
        await settle(host, in: window)
        #expect(host.fittingSize.width == shortWidth, "A reused host must not retain a previous long card's width")
        #expect(findTranslation("你好。", in: host) != nil && findTranslation("Hello.", in: host) != nil)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLanguages = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
            ? ["zh-Hans", "en-US"] : ["de-DE", "en-US", "zh-Hans"]
        recognition.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
        let painted = (recognition.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])
            .joined().lowercased().filter { $0.isLetter }
        for label in [String(localized: "Copy source text", table: "Learning"),
                      String(localized: "Copy translation", table: "Learning")] {
            #expect(painted.contains(label.lowercased().filter { $0.isLetter }),
                    "The localized native copy buttons must remain fully visible inside the compact width")
        }
        if let output = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: output).appendingPathComponent("expanded-short-adaptive.png"))
        }
    }

    @Test
    func expandedStreamingKeepsItsWidthUntilTheTranslationIsComplete() async {
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 250),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let id = UUID()
        func card(_ translation: String, complete: Bool) -> LearningSentenceCard {
            let presentation = LearningSentencePresentation(id: id, source: "原文", translation: translation,
                sourceLanguage: .chinese, targetLanguage: .english, caret: .zero, isExpanded: true,
                isGenerating: !complete, message: "", previousTranslation: nil, shortcutLabel: "⌥T",
                unitStage: .ready, isTranslating: !complete)
            return LearningSentenceCard(presentation: presentation, expand: {}, dismiss: {}, sizeChanged: { _ in })
        }
        let host = NSHostingView(rootView: card("Hello", complete: false))
        window.contentView = host
        window.orderFrontRegardless()
        await settle(host, in: window)
        let width = host.fittingSize.width
        let long = String(repeating: "A complete translated sentence. ", count: 5)
        host.rootView = card(long, complete: false)
        await settle(host, in: window)
        #expect(host.fittingSize.width == width, "Partial tokens wrap without remeasuring the window width")
        host.rootView = card(long, complete: true)
        await settle(host, in: window)
        #expect(host.fittingSize.width == 480)
    }

    @Test
    func streamingCardPaintsItsPrefixAndDisablesReplacementUntilComplete() async throws {
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let id = UUID()
        var replacements = 0
        func card(_ text: String, complete: Bool) -> LearningSentenceCard {
            let presentation = LearningSentencePresentation(id: id, source: "我们期待见到你。", translation: text,
                sourceLanguage: .chinese, targetLanguage: .english, caret: .zero, isExpanded: false,
                isGenerating: !complete, message: "", previousTranslation: nil, shortcutLabel: "⌥T",
                canReplace: complete, replacementShortcutLabel: "⌃⌥T", isTranslating: !complete)
            return LearningSentenceCard(presentation: presentation, replace: { replacements += 1 },
                expand: {}, dismiss: {}, sizeChanged: { _ in })
        }
        let hosting = NSHostingView(rootView: card("We look", complete: false))
        window.contentView = hosting
        window.orderFrontRegardless()
        for (text, complete) in [("We look", false), ("We look forward to seeing you.", true)] {
            hosting.rootView = card(text, complete: complete)
            await settle(hosting, in: window)
            #expect(findTranslation(text, in: hosting)?.string == text)
            let count = replacements
            try clickHeaderAction(2, in: hosting, window: window)
            await settle(hosting, in: window)
            #expect(replacements == count + (complete ? 1 : 0))
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let output = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] {
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: output).appendingPathComponent(complete ? "stream-complete.png" : "stream-prefix.png"))
            }
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLanguages = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
                ? ["zh-Hans", "en-US"] : ["en-US", "zh-Hans"]
            recognition.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
            let painted = (recognition.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
            #expect(painted.contains(text))
            #expect(!painted.contains("Generating") && !painted.contains("正在生成"))
            #expect(!painted.contains("Replace") && !painted.contains("替换"))
        }
    }

    @Test
    func compactLongTranslationScrollsToItsEndAndShortContentShrinksAgain() async throws {
        let id = UUID()
        let target = "Opening sentence remains visible. "
            + Array(repeating: "The full translation stays readable inside a compact scrolling viewport.", count: 8)
                .joined(separator: " ") + " Final words remain visible."
        func card(_ text: String) -> LearningSentenceCard {
            let presentation = LearningSentencePresentation(id: id, source: "原文", translation: text,
                sourceLanguage: .chinese, targetLanguage: .english, caret: .zero, isExpanded: false,
                isGenerating: false, message: "", previousTranslation: nil, shortcutLabel: "⌥T", unitStage: .ready)
            return LearningSentenceCard(presentation: presentation, expand: {}, dismiss: {}, sizeChanged: { _ in })
        }
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: card(target))
        window.contentView = hosting
        defer { window.close() }
        window.orderFrontRegardless()
        await settle(hosting, in: window)
        #expect(hosting.fittingSize.height < 250, "Long text must keep a bounded compact viewport")
        let textView = try #require(findTranslation(target, in: hosting))
        #expect(textView.textContainer?.maximumNumberOfLines == 0)
        #expect(textView.textContainer?.lineBreakMode == .byWordWrapping)
        let tail = (target as NSString).range(of: "Final words remain visible")
        textView.scrollRangeToVisible(tail)
        await settle(hosting, in: window)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let output = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("compact-long-tail.png"))
        }
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLanguages = ["en-US"]
        recognition.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
        let painted = (recognition.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
        #expect(painted.contains("Final words remain visible"), "The final line must be painted after scrolling")
        hosting.rootView = card("Hello.")
        await settle(hosting, in: window)
        #expect(hosting.fittingSize.height < 120, "A reused compact card must shrink back for a short translation")
    }

    private func findTranslation(_ text: String, in view: NSView) -> LearningDictionaryTextView? {
        if let textView = view as? LearningDictionaryTextView, textView.string == text { return textView }
        return view.subviews.lazy.compactMap { findTranslation(text, in: $0) }.first
    }

    @Test
    func expansionPaintsTheOriginalTranslationAndMeaningUnit() async throws {
        let id = UUID()
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        defer { window.close() }
        let makeCard: (Bool) -> LearningSentenceCard = { expanded in
            LearningSentenceCard(presentation: Self.presentation(id: id, expanded: expanded),
                expand: {}, dismiss: {}, sizeChanged: { _ in })
        }
        let hosting = NSHostingView(rootView: makeCard(false))
        window.contentView = hosting
        // SwiftUI's content preferences need an attached display pass, as in the real panel.
        // Order this nonactivating window without making it key or changing the user's editor.
        window.orderFrontRegardless()
        await settle(hosting, in: window)
        let compactHeight = hosting.fittingSize.height
        #expect(compactHeight < 120)
        // Reuse one host and document, matching the real panel's preservation of SwiftUI state.
        for expanded in [true, false, true] {
            hosting.rootView = makeCard(expanded)
            await settle(hosting, in: window)
        }
        #expect(hosting.fittingSize.height > compactHeight,
                "Expanding must add the original without relying on removed caption rows for height")
        #expect(hosting.fittingSize.height < 400)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if let output = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("expanded-sentence.png"))
        }
        let cgImage = try #require(bitmap.cgImage)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLanguages = ["en-US"]
        recognition.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: cgImage).perform([recognition])
        let lines = recognition.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        #expect(lines.contains { $0.contains("Source content must remain visible") })
        #expect(lines.contains { $0.contains("Target translation must remain visible") })
        // Mapping is now embedded in the sentences. Dictionary and duplicate mapping rows no
        // longer belong to this main card; both source and target must still be visibly painted.
        hosting.rootView = LearningSentenceCard(presentation: Self.presentation(id: id, expanded: true, repeats: 3),
            expand: {}, dismiss: {}, sizeChanged: { _ in })
        await settle(hosting, in: window)
        let longer = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: longer)
        if let output = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] {
            try longer.representation(using: .png, properties: [:])?.write(
                to: URL(fileURLWithPath: output).appendingPathComponent("expanded-long.png"))
        }
        let longRecognition = VNRecognizeTextRequest()
        longRecognition.recognitionLanguages = ["en-US"]
        longRecognition.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: try #require(longer.cgImage)).perform([longRecognition])
        let longText = (longRecognition.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined(separator: " ")
        #expect(longText.contains("Source content must remain visible") && longText.contains("Target translation must remain visible"))
    }

    @Test(arguments: [false, true])
    func scopedReplacementAndBothRecoveryActionsStayVisible(_ dark: Bool) async throws {
        let nativeReview = ProcessInfo.processInfo.environment["COTABBY_UI_NATIVE_REVIEW"] == "1"
        let window = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: nativeReview ? [.titled] : [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let id = UUID()
        let replacementShortcutLabel = "REPLACE_SHORTCUT_SENTINEL"
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let vocabulary = VocabularyStore(archive: VocabularyArchive(url: nil))
        let explanation = LearningExplanationSession()
        var replacements = 0, expansions = 0
        func card(expanded: Bool) -> LearningSentenceCard {
            var presentation = Self.presentation(id: id, expanded: expanded, shortcutLabel: "EXPAND_SHORTCUT_SENTINEL")
            presentation.targetIsSelection = true
            presentation.canReplace = true
            presentation.replacementShortcutLabel = replacementShortcutLabel
            let input = LearningExplanationPolicy.input(presentation)
            #expect(input != nil)
            if let input {
                explanation.setTarget(input, saved: .init(id: UUID(), input: input, language: .english,
                    result: .init(meaning: "Contextual meaning.", explanation: "An explanation tied to this sentence."),
                    model: "fixture", createdAt: Date()))
            }
            return LearningSentenceCard(
                presentation: presentation, explanation: explanation,
                replace: { replacements += 1 }, expand: { expansions += 1 }, dismiss: {},
                speech: speech, vocabulary: vocabulary, sizeChanged: { _ in })
        }
        let hosting = NSHostingView(rootView: card(expanded: false))
        window.contentView = hosting
        window.orderFrontRegardless()
        for expanded in [false, true] {
            hosting.rootView = card(expanded: expanded)
            await settle(hosting, in: window)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if let output = ProcessInfo.processInfo.environment["COTABBY_UI_SCREENSHOT_DIR"] {
                let name = "replacement-\(expanded ? "expanded" : "compact")-\(dark ? "dark" : "light").png"
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: output).appendingPathComponent(name))
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = [Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh-Hans" : "en-US"]
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
            let text = (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []).joined()
            func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
            let visible = normalized(text)
            #expect(!visible.contains(normalized(String(localized: "Target: Selection", table: "Learning"))))
            #expect(!visible.contains(normalized(String(localized: "Replace", table: "Learning"))),
                "The replacement action must use only its icon")
            // Both controls must accept the same center and edge clicks within their 22pt hit
            // boxes, not just a click on the painted SF Symbol. These are real SwiftUI gestures.
            for offset in [-10.0, 0, 10] {
                let previous = (replacements, expansions)
                try clickHeaderAction(2, offset: offset, in: hosting, window: window)
                try clickHeaderAction(1, offset: offset, in: hosting, window: window)
                await settle(hosting, in: window)
                #expect(replacements == previous.0 + 1 && expansions == previous.1 + 1)
            }
            #expect(!visible.contains("shortcutsentinel"), "Keyboard shortcut hints must not occupy either card size")
            #expect(!visible.contains(normalized(String(localized: "Target expression", table: "Learning"))))
            #expect(visible.contains(normalized(LearningLanguage.english.label)))
            #expect(visible.components(separatedBy: normalized(LearningLanguage.english.compactLabel)).count == 2,
                "The language belongs in the header once, without a repeated body label")
            let explanationLabel = String(localized: "AI explanation", table: "Learning")
            #expect(!visible.contains(normalized(explanationLabel)))
            if expanded {
                #expect(visible.contains(normalized(String(localized: "Copy source text", table: "Learning"))))
                #expect(visible.contains(normalized(String(localized: "Copy translation", table: "Learning"))))
            }
            if nativeReview, !dark, expanded {
                // Opt-in local acceptance exposes a normal window to an external AX client.
                // NSHostingView's in-process children omit SwiftUI's virtual accessibility tree.
                window.title = "Lingrove card details acceptance"
                try await Task.sleep(for: .seconds(45))
            }
        }
    }

    @Test
    func unsupportedReplacementReasonAndDisabledActionStayVisibleCollapsedAndExpanded() async throws {
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let id = UUID()
        let reason = LearningInputMethodPolicy.unavailableMarkedRangeReason
        let replacementShortcutLabel = "⌃⌥T"
        var replacements = 0
        func card(expanded: Bool) -> LearningSentenceCard {
            var presentation = Self.presentation(id: id, expanded: expanded)
            presentation.canReplace = false
            presentation.replacementShortcutLabel = replacementShortcutLabel
            presentation.replacementUnavailableReason = reason
            return LearningSentenceCard(presentation: presentation, replace: { replacements += 1 },
                expand: {}, dismiss: {}, sizeChanged: { _ in })
        }
        let hosting = NSHostingView(rootView: card(expanded: false))
        window.contentView = hosting
        window.orderFrontRegardless()

        for expanded in [false, true] {
            hosting.rootView = card(expanded: expanded)
            await settle(hosting, in: window)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = [Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true ? "zh-Hans" : "en-US"]
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
            let visible = (request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])
                .joined().lowercased().filter { $0.isLetter || $0.isNumber }
            let reasonPrefix = String(reason.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(30))
            #expect(visible.contains(reasonPrefix), "The replacement reason remains visible in both card sizes.")
            try clickHeaderAction(2, in: hosting, window: window)
            await settle(hosting, in: window)
            #expect(replacements == 0)
        }
    }

    /// Header icons share 22pt targets, an 8pt gap and 10pt outer padding. Send mouse-down and
    /// mouse-up synchronously in gesture order, as the existing popover interaction tests do.
    private func clickHeaderAction(_ trailingIndex: Int, offset: CGFloat = 0,
                                   in host: NSView, window: NSWindow) throws {
        let point = CGPoint(x: host.bounds.width - 21 - CGFloat(trailingIndex) * 30 + offset,
            y: host.isFlipped ? 21 : host.bounds.height - 21)
        let location = host.convert(point, to: nil), timestamp = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0))
        window.sendEvent(down); window.sendEvent(up)
    }

    private func settle(_ hosting: NSHostingView<LearningSentenceCard>, in window: NSWindow) async {
        for _ in 0..<8 {
            hosting.layoutSubtreeIfNeeded()
            window.setContentSize(hosting.fittingSize)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func presentation(id: UUID, expanded: Bool, repeats: Int = 1,
                                     shortcutLabel: String = "⌥T") -> LearningSentencePresentation {
        let source = Array(repeating: "Source content must remain visible.", count: repeats).joined(separator: " ")
        let target = Array(repeating: "Target translation must remain visible.", count: repeats).joined(separator: " ")
        return LearningSentencePresentation(id: id, source: source, translation: target,
            sourceLanguage: .chinese, targetLanguage: .english, caret: .zero,
            isExpanded: expanded, isGenerating: false, message: "", previousTranslation: nil,
            shortcutLabel: shortcutLabel, unitStage: .ready)
    }
}
