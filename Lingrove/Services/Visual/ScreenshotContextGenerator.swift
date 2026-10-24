import CoreGraphics
import Foundation
import Logging

/// File overview:
/// Converts the focused input's window or surrounding crop into OCR text for prompt injection.
/// The pipeline is: focused snapshot -> screenshot -> Apple OCR -> cleanup/selection -> bounded
/// visible-context excerpt.
///
/// Keeping capture and OCR cleanup at this boundary gives the suggestion coordinator a small
/// plain-text value instead of exposing raw screenshots or OCR implementation details.

enum ScreenshotContextGenerationError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .failed(let message):
            return message
        }
    }
}

/// Async seam for field-scoped refresh tests; implementations own capture/OCR, not scheduling.
@MainActor
protocol ScreenshotContextGenerating {
    func generateContext(
        for context: FocusedInputSnapshot,
        configuration: VisualContextConfiguration?,
        onStatusChange: (@MainActor @Sendable (VisualContextStatus) -> Void)?
    ) async throws -> VisualContextExcerpt
}

@MainActor
final class ScreenshotContextGenerator: ScreenshotContextGenerating {
    private enum ContextSource: String {
        case ocrFallback = "ocr_fallback"
    }

    private let screenshotService: any WindowScreenshotCapturing
    private let ocrRuntime: OCRRuntime
    private let debugScreenshotWriter: DebugScreenshotWriter?
    private let textExtractor: (any ScreenTextExtracting)?
    private let configuration: VisualContextConfiguration

    /// Recent OCR extractions keyed by a pixel hash of the captured crop, so refocusing a window
    /// whose content has not changed skips the Vision pass (the dominant cost of this pipeline).
    /// Only the raw extraction is cached: hygiene and bounding still rerun against the live field
    /// text below, so a cache hit stays byte-identical to re-OCRing identical pixels. Bounded to a
    /// few entries so alt-tabbing between two or three windows keeps hitting.
    private var extractionCache: [CachedExtraction] = []

    /// One bounded cache entry couples pixels and capture policy to their OCR result.
    /// The generator owns it until eviction; live-field hygiene is never cached here.
    private struct CachedExtraction {
        let hash: UInt64
        let configuration: VisualContextConfiguration
        let extracted: ExtractedScreenText
    }
    private static let extractionCacheLimit = 4

    init(
        ocrRuntime: OCRRuntime,
        debugScreenshotWriter: DebugScreenshotWriter? = nil,
        screenshotService: (any WindowScreenshotCapturing)? = nil,
        textExtractor: (any ScreenTextExtracting)? = nil,
        configuration: VisualContextConfiguration? = nil
    ) {
        let actualConfig = configuration ?? .default
        self.ocrRuntime = ocrRuntime
        self.debugScreenshotWriter = debugScreenshotWriter
        self.screenshotService = screenshotService ?? WindowScreenshotService()
        self.textExtractor = textExtractor
        self.configuration = actualConfig
    }

    /// Captures according to the selected engine's privacy profile and returns bounded text.
    /// An override lives only for this call; switching engines cannot reuse a mutable configuration.
    func generateContext(
        for context: FocusedInputSnapshot,
        configuration override: VisualContextConfiguration? = nil,
        onStatusChange: (@MainActor @Sendable (VisualContextStatus) -> Void)? = nil
    ) async throws -> VisualContextExcerpt {
        let configuration = override ?? self.configuration
        let screenshot = try await captureScreenshot(for: context, configuration: configuration, onStatusChange: onStatusChange)
        try Task.checkCancellation()

        onStatusChange?(.extractingText)

        let pixelHash = await Task.detached(priority: .utility) { Self.pixelHash(of: screenshot.image) }.value
        try Task.checkCancellation()
        if let pixelHash, let cached = cachedExtraction(for: pixelHash, configuration: configuration) {
            return try await finishedExcerpt(from: cached, context: context, screenshot: screenshot,
                                             configuration: configuration, recordsDebugCapture: false)
        }

        let extracted: ExtractedScreenText
        do {
            let extractor = textExtractor ?? ScreenTextExtractor(
                runtime: ocrRuntime,
                maxImageDimension: configuration.maxImageDimension,
                maxRecognizedCharacters: configuration.maxRecognizedCharacters
            )
            extracted = try await extractor.extractText(from: screenshot.image)
            try Task.checkCancellation()
        } catch ScreenTextExtractionError.noRecognizedText {
            guard let windowTitle = screenshot.windowTitle else {
                throw ScreenshotContextGenerationError.unavailable(
                    "The screenshot did not contain enough visible text to build prompt context."
                )
            }

            let normalizedTitle = normalizeRecognizedText(windowTitle, configuration: configuration)
            guard hasMeaningfulSignal(normalizedTitle, configuration: configuration)
            else {
                throw ScreenshotContextGenerationError.unavailable(
                    "The screenshot did not contain enough visible text to build prompt context."
                )
            }

            let finalTitleContext = boundedSummaryText(normalizedTitle, configuration: configuration)
            LingroveLogger.app.debug(
                "Visual context ready source=\(ContextSource.ocrFallback.rawValue) chars=\(finalTitleContext.count)"
            )
            return VisualContextExcerpt(text: finalTitleContext)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ScreenTextExtractionError {
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }

        storeExtraction(extracted, for: pixelHash, configuration: configuration)
        return try await finishedExcerpt(from: extracted, context: context, screenshot: screenshot, configuration: configuration)
    }

    /// Hygiene, normalization, bounding, and the meaningful-signal gate, shared by the fresh and
    /// cache-hit paths so a hit stays byte-identical to re-OCRing the same pixels. The field-text
    /// stripping in particular must rerun per call: the cached extraction may have been taken when
    /// the user's own typed text differed.
    private func finishedExcerpt(
        from extracted: ExtractedScreenText,
        context: FocusedInputSnapshot,
        screenshot: CapturedWindowScreenshot,
        configuration: VisualContextConfiguration,
        recordsDebugCapture: Bool = true
    ) async throws -> VisualContextExcerpt {
        // Filter OCR corruption (garbled / symbol-noise / digit-substituted lines) and strip any
        // line that merely echoes the user's own field text, then sanitize for prompt-injection
        // safety. No model summarization: a base model conditions fine on cleaned raw context, and
        // the old summary step cost an extra generation per refresh and could hallucinate.
        let normalizedText = await Task.detached(priority: .utility) {
            let cleanedOCR = configuration.capturesEntireWindow ? VisualContextExcerptSelector.select(
                lines: extracted.lines,
                fieldText: context.precedingText + " " + context.trailingText,
                focusBounds: screenshot.focusBounds,
                maxCharacters: configuration.maxSummaryCharacters
            ) : OCRTextHygiene.clean(
                lines: extracted.lines,
                fieldText: context.precedingText + " " + context.trailingText,
                maxChars: configuration.maxRecognizedCharacters
            )
            return configuration.capturesEntireWindow
                ? PromptContextSanitizer.sanitize(cleanedOCR, maxCharacters: configuration.maxRecognizedCharacters)
                : PromptContextSanitizer.sanitizeOCR(cleanedOCR, maxCharacters: configuration.maxRecognizedCharacters)
        }.value
        try Task.checkCancellation()

        if recordsDebugCapture {
            // Identical-pixel cache hits have the same raw image/OCR pair. Keeping another PNG
            // adds only diagnostic I/O; delivery of the live excerpt never waits for storage.
            debugScreenshotWriter?.submit(image: screenshot.image, text: extracted.text,
                                          applicationName: context.applicationName)
        }

        let finalContextText = boundedSummaryText(normalizedText, configuration: configuration)
        guard hasMeaningfulSignal(finalContextText, configuration: configuration) else {
            throw ScreenshotContextGenerationError.unavailable(
                "The screenshot did not contain enough visible text to build prompt context."
            )
        }

        LingroveLogger.app.debug(
            "Visual context ready source=\(ContextSource.ocrFallback.rawValue) chars=\(finalContextText.count)"
        )

        return VisualContextExcerpt(text: finalContextText)
    }

    // MARK: - Extraction cache

    /// FNV-1a over a strided sample of the image bytes, mixed with the dimensions. Sampling every
    /// 16th byte keeps the hash sub-millisecond on Retina crops while still touching every row;
    /// any real content change moves enough antialiased pixels that a stride collision is
    /// vanishingly unlikely, and the worst case of one is reusing OCR text for a window whose
    /// pixels barely changed. `nil` (no readable backing data) simply disables caching.
    nonisolated private static func pixelHash(of image: CGImage) -> UInt64? {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let length = CFDataGetLength(data)
        let prime: UInt64 = 0x0000_0100_0000_01B3
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        var index = 0
        // 17, not 16: with 4-byte pixels a multiple-of-4 stride lands on the same color channel
        // forever, so a chroma-only change (e.g. a theme toggle with unchanged luminance) could
        // hash identically. A stride coprime with the pixel size cycles through all four channels.
        while index < length {
            hash = (hash ^ UInt64(bytes[index])) &* prime
            index += 17
        }
        hash = (hash ^ UInt64(image.width)) &* prime
        hash = (hash ^ UInt64(image.height)) &* prime
        return hash
    }

    private func cachedExtraction(for hash: UInt64, configuration: VisualContextConfiguration) -> ExtractedScreenText? {
        extractionCache.first(where: { $0.hash == hash && $0.configuration == configuration })?.extracted
    }

    private func storeExtraction(_ extracted: ExtractedScreenText, for hash: UInt64?, configuration: VisualContextConfiguration) {
        guard let hash else {
            return
        }

        extractionCache.removeAll { $0.hash == hash }
        extractionCache.append(CachedExtraction(hash: hash, configuration: configuration, extracted: extracted))
        if extractionCache.count > Self.extractionCacheLimit {
            extractionCache.removeFirst(extractionCache.count - Self.extractionCacheLimit)
        }
    }

    private func captureScreenshot(
        for context: FocusedInputSnapshot,
        configuration: VisualContextConfiguration,
        onStatusChange: (@MainActor @Sendable (VisualContextStatus) -> Void)?
    ) async throws -> CapturedWindowScreenshot {
        onStatusChange?(.capturing)
        do {
            return try await screenshotService.captureSnapshot(
                around: context,
                snapshotDimension: configuration.snapshotDimension,
                capturesEntireWindow: configuration.capturesEntireWindow
            )
        } catch let error as WindowScreenshotError {
            throw ScreenshotContextGenerationError.unavailable(error.localizedDescription)
        } catch {
            throw ScreenshotContextGenerationError.failed(error.localizedDescription)
        }
    }

    /// OCR is noisy by nature. We normalize line whitespace, strip short-token noise from UI
    /// chrome, and keep only a bounded excerpt so the prompt receives meaningful text.
    private func normalizeRecognizedText(_ rawText: String, configuration: VisualContextConfiguration) -> String {
        PromptContextSanitizer.sanitizeOCR(
            rawText,
            maxCharacters: configuration.maxRecognizedCharacters
        )
    }

    /// Applies the final prompt-injection budget after OCR cleanup.
    ///
    /// `maxRecognizedCharacters` bounds OCR cleanup input. This separate cap protects the
    /// autocomplete prompt from a verbose recognized-text result.
    private func boundedSummaryText(_ text: String, configuration: VisualContextConfiguration) -> String {
        PromptContextSanitizer.sanitize(
            text,
            maxCharacters: configuration.maxSummaryCharacters
        )
    }

    /// We reject OCR text that is mostly punctuation or numeric noise because that would hurt
    /// the completion prompt more than help it.
    private func hasMeaningfulSignal(_ text: String, configuration: VisualContextConfiguration) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= configuration.minRecognizedCharacterCount else {
            return false
        }

        let letterCount = trimmed.unicodeScalars.filter(CharacterSet.letters.contains).count
        return letterCount >= 4
    }

}
