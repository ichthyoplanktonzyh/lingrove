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
    private let ocrRuntime: OCRRuntime
    private let visualReader: LearningReadingVisualReader
    private let metrics: PerformanceMetricsStore?
    private let trackingEnabled: () -> Bool
    private var receipt: LearningReadingSelection?
    private var window: AXUIElement?
    private var windowFrame: CGRect?
    private var visualRegion: WindowScreenshotService.ReadingRegion?
    private var revision = UUID()
    /// Retained only for an AX pointer receipt. The range verifies a word without rereading a page.
    private struct PointerEvidence {
        let element: AXUIElement
        let range: NSRange
        let text: String
    }
    /// One spatial hit from OCR or AX. Only the active receipt retains its window/occurrence
    /// evidence; the shared card receives text and context, never capture implementation state.
    struct PointedText {
        let text: String
        let anchor: CGRect
        let hint: LearningLanguage?
        let context: LearningReadingContext?
        var capturedAt = Date()
        var visualRegion: WindowScreenshotService.ReadingRegion?
    }
    private struct RecognizedText {
        let text: String
        let hint: LearningLanguage?
        let context: LearningReadingContext?
    }
    private var pointerEvidence: PointerEvidence?
    var isSelectingRegion: Bool { picker.isSelecting }

    init(ocrRuntime: OCRRuntime, metrics: PerformanceMetricsStore? = nil, trackingEnabled: @escaping () -> Bool = { false }) {
        self.ocrRuntime = ocrRuntime
        self.visualReader = LearningReadingVisualReader(runtime: ocrRuntime)
        self.metrics = metrics
        self.trackingEnabled = trackingEnabled
    }

    func setInvalidationHandler(_ handler: (@MainActor () -> Void)?) {
        selection.setInvalidationHandler(handler)
    }
    func forget() {
        revision = UUID()
        picker.cancel()
        selection.forget()
        receipt = nil
        window = nil
        windowFrame = nil
        visualRegion = nil
        pointerEvidence = nil
    }
    func capture() async throws -> LearningReadingSelection { try await capture(source: .selection) }

    func capture(source: LearningReadingSource) async throws -> LearningReadingSelection {
        try await LearningRequestTrace.$requestID.withValue(LearningRequestTrace.requestID ?? RequestID.generate()) {
            try await captureSource(source)
        }
    }

    private func captureSource(_ source: LearningReadingSource) async throws -> LearningReadingSelection {
        forget()
        guard source != .selection else { return try await selection.capture() }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { throw CancellationError() }
        let originWindow = focusedWindow(app.processIdentifier)
        let originFrame = frame(of: originWindow)
        let id = revision
        let validate = { self.revision == id && self.isOriginCurrent(pid: app.processIdentifier, window: originWindow) &&
            self.frame(of: originWindow) == originFrame }
        let point = NSEvent.mouseLocation
        let trace = LearningRequestTrace.requestID ?? RequestID.generate()
        var anchor = CGRect(origin: point, size: CGSize(width: 1, height: 18))
        let text: String
        var languageHint: LearningLanguage?
        var readingContext: LearningReadingContext?
        var capturedAt = Date()
        var capturedRegion: WindowScreenshotService.ReadingRegion?
        if source == .pointer {
            let hit = try await readPointer(at: point, pid: app.processIdentifier, trace: trace, validate: validate)
            text = hit.text
            anchor = hit.anchor
            languageHint = hit.hint
            readingContext = hit.context
            capturedAt = hit.capturedAt
            capturedRegion = hit.visualRegion
        } else {
            guard CGPreflightScreenCaptureAccess() else {
                throw LearningFailure.message(
                    String(
                        localized:
                            "Allow Screen Recording for Lingrove in System Settings to translate screen text.",
                        table: "Learning"))
            }
            let region = try await picker.select()
            try Task.checkCancellation()
            guard validate() else {
                throw CancellationError()
            }
            let recognized = try await recognize(
                region: region, trace: trace)
            text = recognized.text
            languageHint = recognized.hint
            readingContext = recognized.context
            anchor = region
        }
        try Task.checkCancellation()
        try LearningReadingPolicy.validate(text)
        guard validate() else {
            throw CancellationError()
        }
        let result = LearningReadingSelection(
            id: UUID(), text: text, processIdentifier: app.processIdentifier,
            bundleIdentifier: bundle, anchor: anchor, source: source, languageHint: languageHint,
            context: readingContext, traceID: trace, capturedAt: capturedAt)
        receipt = result
        window = originWindow
        windowFrame = originFrame
        visualRegion = capturedRegion
        return result
    }

    func isCurrent(_ capture: LearningReadingSelection) -> Bool {
        if capture.source == .selection { return selection.isCurrent(capture) }
        guard receipt?.id == capture.id, isOriginCurrent(pid: capture.processIdentifier, window: window), frame(of: window) == windowFrame
        else { return false }
        if let visualRegion, !screenshots.isCurrent(visualRegion) { return false }
        if let evidence = pointerEvidence {
            return AXHelper.parameterizedStringValue(
                for: kAXStringForRangeParameterizedAttribute as CFString,
                range: evidence.range, on: evidence.element)?.utf16.elementsEqual(evidence.text.utf16) == true
        }
        return true
    }

    private func focusedWindow(_ pid: Int32) -> AXUIElement? {
        AXHelper.elementValue(
            for: kAXFocusedWindowAttribute as CFString, on: AXUIElementCreateApplication(pid))
    }
    private func frame(of window: AXUIElement?) -> CGRect? {
        window.flatMap { AXHelper.accessibilityFrame(of: $0) }.map { AXHelper.cocoaRect(fromAccessibilityRect: $0) }
    }

    /// OCR owns the normal pointer route. AX remains a bounded fallback, including when Screen
    /// Recording was never granted. Cancellation/viewport changes always retire both routes.
    private func readPointer(at point: CGPoint, pid: Int32, trace: String,
                             validate: @escaping () -> Bool) async throws -> PointedText {
        if AXIsProcessTrusted() { try validatePointer(at: point, pid: pid) }
        var visual: (() async throws -> PointedText)?
        if CGPreflightScreenCaptureAccess() {
            visual = {
                let started = ProcessInfo.processInfo.systemUptime
                let deadline = started + 12
                let region = try await self.screenshots.pointerCaptureRegion(at: point, pid: pid, deadline: deadline)
                let result = try await self.visualReader.read(at: point, bounds: region.bounds, deadline: deadline) {
                    validate() && self.screenshots.isCurrent(region)
                }
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
                LingroveLogger.learning.info("Reading visual capture finished", metadata: [
                    "request_id": .string(trace), "stage": "ocr", "origin": "pointer", "reading_route": "ocr",
                    "ocr_passes": .stringConvertible(result.passes), "latency_ms": .stringConvertible(elapsed)
                ])
                if self.trackingEnabled() {
                    self.metrics?.record(modelName: "Apple Vision", latencyMs: elapsed, source: .ocr,
                        outcome: .completed, requestID: trace, usableResultMs: elapsed)
                }
                LearningVocabularyContextReader.log(result.context)
                return PointedText(text: result.text, anchor: result.anchor, hint: result.context?.languageHint,
                    context: result.context, capturedAt: result.capturedAt, visualRegion: region)
            }
        }
        do {
            return try await Self.capturePointer(visual: visual, fallback: {
                guard AXIsProcessTrusted(), let hit = try self.pointedText(at: point, pid: pid) else { return nil }
                LingroveLogger.learning.info("Reading pointer used AX fallback", metadata: [
                    "request_id": .string(trace), "stage": "capture", "reading_route": "ax-fallback"
                ])
                return hit
            }, validate: validate)
        } catch is LearningReadingVisualReader.Failure {
            if !CGPreflightScreenCaptureAccess() {
                throw LearningFailure.message(String(
                    localized: "Allow Screen Recording for Lingrove in System Settings to translate screen text.", table: "Learning"))
            }
            throw LearningFailure.message(String(localized: "No word was found under the pointer.", table: "Learning"))
        }
    }

    /// Both native routes cross the same lifetime check. The optional visual closure represents
    /// missing capture permission/geometry; cancellation can never turn into an AX retry.
    static func capturePointer(visual: (() async throws -> PointedText)?, fallback: () throws -> PointedText?,
                               validate: () -> Bool) async throws -> PointedText {
        try Task.checkCancellation()
        guard validate() else { throw CancellationError() }
        var failure: (any Error)?
        if let visual {
            do {
                let result = try await visual()
                try Task.checkCancellation()
                guard validate() else { throw CancellationError() }
                return result
            } catch {
                try Task.checkCancellation()
                guard !(error is CancellationError), validate() else { throw CancellationError() }
                failure = error
            }
        }
        try Task.checkCancellation()
        guard validate() else { throw CancellationError() }
        if let result = try fallback() {
            guard validate() else { throw CancellationError() }
            return result
        }
        throw failure ?? LearningReadingVisualReader.Failure.noTarget
    }

    /// Check only ownership and sensitive-field ancestry before capturing pixels. This does not
    /// read text/ranges; an OCR-first route must retain the former AX route's secure-field guard.
    /// Missing AX evidence does not certify a field as safe; explicit pixel capture remains
    /// available as it already is for images/region reading when Accessibility is unavailable.
    private func validatePointer(at point: CGPoint, pid: Int32) throws {
        var candidate = AXHelper.element(atCocoaPoint: point)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        for _ in 0..<7 {
            guard ContinuousClock.now < deadline, let element = candidate else { return }
            if let owner = AXHelper.owningApplication(of: element), owner.processIdentifier != pid { throw CancellationError() }
            if SecureFieldDetector.isSecure(role: AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element),
                subrole: AXHelper.stringValue(for: kAXSubroleAttribute as CFString, on: element),
                roleDescription: AXHelper.stringValue(for: kAXRoleDescriptionAttribute as CFString, on: element),
                title: AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: element),
                descriptionLabel: AXHelper.stringValue(for: kAXDescriptionAttribute as CFString, on: element)) {
                throw LearningFailure.message(String(localized: "Sensitive fields cannot be translated.", table: "Learning"))
            }
            if AXHelper.stringValue(for: kAXRoleAttribute as CFString, on: element) == kAXApplicationRole { return }
            candidate = AXHelper.elementValue(for: kAXParentAttribute as CFString, on: element)
        }
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
                                    let language = LearningLanguage.detect(in: text)
                                    let context = LearningVocabularyContextReader.read(element: element,
                                        range: target, expected: word.text, selection: false)
                                    return PointedText(text: word.text, anchor: anchor, hint: language, context: context)
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

    private func recognize(region: CGRect, trace: String) async throws -> RecognizedText {
        let started = ProcessInfo.processInfo.systemUptime
        var captureMs = 0
        var outcome = ModelRequestOutcome.failed
        defer {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            LingroveLogger.learning.info(
                "Reading OCR finished",
                metadata: [
                    "request_id": .string(trace),
                    "origin": "screenshot", "stage": "ocr",
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
                runtime: ocrRuntime,
                maxImageDimension: max(image.width, image.height), maxRecognizedCharacters: 1)
            extractor.minimumTextHeight = 0
            extractor.logsTextPreview = false
            extractor.detectsLanguageAutomatically = true
            extractor.purpose = .reading
            let extraction = try await extractor.extractText(from: image)
            try Task.checkCancellation()
            let text = try LearningReadingTextPolicy.text(from: extraction.lines)
            let context = LearningReadingContextPolicy.resolve(.init(text: text,
                target: NSRange(location: 0, length: text.utf16.count), left: .crop, right: .crop, method: .ocr,
                confidence: extraction.lines.map(\.confidence).min()), expected: text)
            LearningVocabularyContextReader.log(context)
            outcome = .completed
            return RecognizedText(text: text, hint: context?.languageHint, context: context)
        } catch {
            if Task.isCancelled || error is CancellationError {
                outcome = .cancelled
                throw CancellationError()
            }
            throw error
        }
    }
}
