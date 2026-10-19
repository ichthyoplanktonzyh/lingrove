import AppKit
import ApplicationServices
import Logging

/// The environment owns this acquisition adapter for the app's lifetime. Selection keeps its
/// existing AX receipt/observer; pointer and region captures retain only text plus origin-window
/// evidence. Images live within one OCR call and are never written to disk or sent to a model.
/// The coordinator owns cancellation and validates the receipt again after each model await.
@MainActor
final class LearningReadingSourceReader: LearningReadingSelecting {
    private let selection = LearningReadingSelectionReader()
    private let picker = LearningRegionSelectionPanel()
    private let screenshots = WindowScreenshotService()
    private let metrics: PerformanceMetricsStore?
    private let trackingEnabled: () -> Bool
    private var receipt: LearningReadingSelection?
    private var window: AXUIElement?
    /// Retained only for an AX pointer receipt. The range verifies a word without rereading a page.
    private struct PointerEvidence {
        let element: AXUIElement
        let range: NSRange
        let text: String
    }
    /// Ephemeral output of the native hit test; the language hint never enters the model prompt.
    private struct PointedText {
        let text: String
        let anchor: CGRect
        let hint: LearningLanguage?
    }
    private var pointerEvidence: PointerEvidence?
    var isSelectingRegion: Bool { picker.isSelecting }

    init(metrics: PerformanceMetricsStore? = nil, trackingEnabled: @escaping () -> Bool = { false }) {
        self.metrics = metrics
        self.trackingEnabled = trackingEnabled
    }

    func setInvalidationHandler(_ handler: (@MainActor () -> Void)?) {
        selection.setInvalidationHandler(handler)
    }
    func forget() {
        picker.cancel()
        selection.forget()
        receipt = nil
        window = nil
        pointerEvidence = nil
    }
    func capture() async throws -> LearningReadingSelection { try await capture(source: .selection) }

    func capture(source: LearningReadingSource) async throws -> LearningReadingSelection {
        forget()
        guard source != .selection else { return try await selection.capture() }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw CancellationError() }
        let originWindow = focusedWindow(app.processIdentifier)
        let point = NSEvent.mouseLocation
        let trace = LearningRequestTrace.requestID ?? RequestID.generate()
        var anchor = CGRect(origin: point, size: CGSize(width: 1, height: 18))
        let text: String
        var languageHint: LearningLanguage?
        if source == .pointer, AXIsProcessTrusted(), let hit = try pointedText(at: point, pid: app.processIdentifier) {
            text = hit.text
            anchor = hit.anchor
            languageHint = hit.hint
        } else {
            guard CGPreflightScreenCaptureAccess() else {
                throw LearningFailure.message(
                    String(
                        localized:
                            "Allow Screen Recording for Lingrove in System Settings to translate screen text.",
                        table: "Learning"))
            }
            let region: CGRect
            if source == .screenshot {
                region = try await picker.select()
            } else {
                guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
                    throw CancellationError()
                }
                region = CGRect(x: point.x - 360, y: point.y - 120, width: 720, height: 240).intersection(
                    screen.frame)
            }
            try Task.checkCancellation()
            guard isOriginCurrent(pid: app.processIdentifier, window: originWindow) else {
                throw CancellationError()
            }
            let recognized = try await recognize(
                region: region, pointer: source == .pointer ? point : nil, trace: trace)
            text = recognized.text
            languageHint = recognized.hint
            anchor = source == .screenshot ? region : anchor
        }
        try Task.checkCancellation()
        try LearningReadingPolicy.validate(text)
        guard isOriginCurrent(pid: app.processIdentifier, window: originWindow) else {
            throw CancellationError()
        }
        let result = LearningReadingSelection(
            id: UUID(), text: text, processIdentifier: app.processIdentifier,
            bundleIdentifier: bundle, anchor: anchor, source: source, languageHint: languageHint)
        receipt = result
        window = originWindow
        return result
    }

    func isCurrent(_ capture: LearningReadingSelection) -> Bool {
        if capture.source == .selection { return selection.isCurrent(capture) }
        guard receipt?.id == capture.id, isOriginCurrent(pid: capture.processIdentifier, window: window)
        else { return false }
        if let evidence = pointerEvidence {
            return AXHelper.parameterizedStringValue(
                for: kAXStringForRangeParameterizedAttribute as CFString,
                range: evidence.range, on: evidence.element) == evidence.text
        }
        return true
    }

    private func focusedWindow(_ pid: Int32) -> AXUIElement? {
        AXHelper.elementValue(
            for: kAXFocusedWindowAttribute as CFString, on: AXUIElementCreateApplication(pid))
    }
    private func isOriginCurrent(pid: Int32, window: AXUIElement?) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        let current = focusedWindow(pid)
        switch (window, current) {
        case (let old?, let new?): return CFEqual(old, new)
        case (nil, nil): return true
        default: return false
        }
    }

    // swiftlint:disable cyclomatic_complexity
    /// All native values stay at this boundary. AX owns returned CF values; Swift's bridge retains
    /// them for this scope. Point/range bounds must agree, so an editor's nearest-character answer
    /// cannot translate a word from another line. Unsupported hosts fall back to explicit local OCR.
    /// AX ancestors have distinct optional capabilities; every guard protects the same hit-test walk.
    private func pointedText(at point: CGPoint, pid: Int32) throws -> PointedText? {
        var candidate = AXHelper.element(atCocoaPoint: point)
        if let hit = candidate, let owner = AXHelper.owningApplication(of: hit), owner.processIdentifier != pid {
            throw LearningFailure.message(String(localized: "Selection is unavailable in this app.", table: "Learning"))
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        for _ in 0..<7 {
            guard ContinuousClock.now < deadline, let element = candidate,
                AXHelper.owningApplication(of: element)?.processIdentifier == pid
            else { break }
            guard
                !SecureFieldDetector.isSecure(
                    role: AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element),
                    subrole: AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element),
                    roleDescription: AXHelper.stringValue(
                        for: kAXRoleDescriptionAttribute as CFString, on: element),
                    title: AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element),
                    descriptionLabel: AXHelper.stringValue(
                        for: kAXDescriptionAttribute as CFString, on: element))
            else {
                throw LearningFailure.message(
                    String(localized: "Sensitive fields cannot be translated.", table: "Learning"))
            }
            var axPoint = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
            if let parameter = AXValueCreate(.cgPoint, &axPoint) {
                var result: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    element, kAXRangeForPositionParameterizedAttribute as CFString,
                    parameter, &result) == .success, let result, CFGetTypeID(result) == AXValueGetTypeID() {
                    var hitRange = CFRange()
                    let axValue = unsafeBitCast(result, to: AXValue.self)
                    guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &hitRange)
                    else { return nil }
                    let index = hitRange.location
                    let count =
                        AXHelper.intValue(for: kAXNumberOfCharactersAttribute as CFString, on: element) ?? 0
                    if index >= 0, index < count {
                        let start = max(0, index - 256)
                        let range = NSRange(location: start, length: min(count - start, 512))
                        if let text = AXHelper.parameterizedStringValue(
                            for: kAXStringForRangeParameterizedAttribute as CFString,
                            range: range, on: element),
                            let word = LearningReadingTextPolicy.word(in: text, utf16Index: index - start) {
                            guard start == 0 || word.range.location > 0,
                                start + range.length == count || NSMaxRange(word.range) < text.utf16.count
                            else { return nil }
                            let target = NSRange(location: start + word.range.location, length: word.range.length)
                            if let bounds = AXHelper.parameterizedRectValue(
                                for: kAXBoundsForRangeParameterizedAttribute as CFString,
                                range: target, on: element) {
                                let anchor = AXHelper.validatedCocoaTextRect(
                                    fromAccessibilityRect: bounds,
                                    anchorFrame: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
                                if anchor.insetBy(dx: -2, dy: -2).contains(point) {
                                    pointerEvidence = PointerEvidence(element: element, range: target, text: word.text)
                                    return PointedText(text: word.text, anchor: anchor, hint: LearningLanguage.detect(in: text))
                                }
                            }
                        }
                    }
                }
            }
            candidate = AXHelper.elementValue(for: kAXParentAttribute as CFString, on: element)
        }
        return nil
    }
    // swiftlint:enable cyclomatic_complexity

    private func recognize(region: CGRect, pointer: CGPoint?, trace: String) async throws -> (
        text: String, hint: LearningLanguage?
    ) {
        let started = ProcessInfo.processInfo.systemUptime
        var captureMs = 0
        var outcome = ModelRequestOutcome.failed
        defer {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            CotabbyLogger.learning.info(
                "Reading OCR finished",
                metadata: [
                    "request_id": .string(trace),
                    "origin": .string(pointer == nil ? "screenshot" : "pointer"), "stage": "ocr",
                    "capture_ms": .stringConvertible(captureMs),
                    "ocr_ms": .stringConvertible(max(0, elapsed - captureMs)),
                    "latency_ms": .stringConvertible(elapsed), "outcome": .string(outcome.rawValue)
                ])
            if trackingEnabled() {
                metrics?.record(
                    modelName: "Apple Vision", latencyMs: elapsed, source: .ocr,
                    outcome: outcome, requestID: trace, firstOutputMs: captureMs,
                    usableResultMs: outcome == .completed ? elapsed : nil)
            }
        }
        do {
            let image = try await screenshots.captureRegion(region)
            captureMs = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            // Keep original pixels and all recognized lines. The context extractor's capped text
            // field is deliberately ignored, and zero minimum height retains small target text.
            var extractor = ScreenTextExtractor(
                maxImageDimension: max(image.width, image.height), maxRecognizedCharacters: 1)
            extractor.minimumTextHeight = 0
            extractor.capturesWordBounds = pointer != nil
            extractor.logsTextPreview = false
            extractor.detectsLanguageAutomatically = true
            let extraction = try await extractor.extractText(from: image)
            try Task.checkCancellation()
            let text: String
            if let pointer {
                let unit = CGPoint(
                    x: (pointer.x - region.minX) / region.width, y: (pointer.y - region.minY) / region.height)
                guard let word = extraction.words.first(where: { $0.boundingBox.contains(unit) }),
                    word.text.contains(where: \.isLetter)
                else {
                    throw LearningFailure.message(
                        String(localized: "No word was found under the pointer.", table: "Learning"))
                }
                text = word.text
            } else {
                text = try LearningReadingTextPolicy.text(from: extraction.lines)
            }
            outcome = .completed
            let hint = pointer.flatMap { point in
                let unit = CGPoint(
                    x: (point.x - region.minX) / region.width, y: (point.y - region.minY) / region.height)
                return extraction.lines.first(where: { $0.boundingBox?.contains(unit) == true }).flatMap {
                    LearningLanguage.detect(in: $0.text)
                }
            }
            return (text, hint)
        } catch {
            if Task.isCancelled || error is CancellationError {
                outcome = .cancelled
                throw CancellationError()
            }
            throw error
        }
    }
}
