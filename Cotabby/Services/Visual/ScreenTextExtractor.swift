import CoreGraphics
import Foundation
import Logging
import NaturalLanguage
@preconcurrency import Vision

/// File overview:
/// Runs OCR over a captured window screenshot and returns a reading-order text excerpt.
/// This is the bridge between raw image capture and the existing text-only local LLM runtime.
///
/// We deliberately downsample very large screenshots before OCR. The goal is not archival fidelity;
/// it is bounded semantic extraction for autocomplete context. This pass favors useful text
/// recovery over minimum latency because refresh runs independently of prediction generation.

struct ExtractedScreenText: Sendable {
    let text: String
    let lineCount: Int
    /// Per-line OCR text paired with Vision's recognition confidence, in reading order. Carries the
    /// confidence that the joined `text` discards, so `OCRTextHygiene.dropLowConfidence` can filter on
    /// real values instead of a synthesized constant. Defaults to empty for callers (and tests) that
    /// only supply joined text.
    let lines: [OCRTextHygiene.OCRLine]
    let words: [ScreenTextWord]

    init(text: String, lineCount: Int, lines: [OCRTextHygiene.OCRLine] = [], words: [ScreenTextWord] = []) {
        self.text = text
        self.lineCount = lineCount
        self.lines = lines
        self.words = words
    }
}

/// Optional word geometry belongs to OCR output, not the view. Only explicit pointer queries
/// request it; ordinary autocomplete extraction pays no per-word tokenization/box-query cost.
nonisolated struct ScreenTextWord: Sendable {
    let text: String
    let boundingBox: CGRect
}

/// Test seam for screenshot OCR.
///
/// `ScreenshotContextGenerator` owns orchestration, while this protocol lets tests inject
/// deterministic OCR without depending on Vision, Screen Recording permission, or real pixels.
protocol ScreenTextExtracting {
    func extractText(from image: CGImage) async throws -> ExtractedScreenText
}

enum ScreenTextExtractionError: LocalizedError {
    case noRecognizedText
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecognizedText:
            return String(localized: "No usable visible text was recognized in the screenshot.")
        case let .ocrFailed(message):
            return String(localized: "Screenshot OCR failed: \(message)")
        }
    }
}

/// Guards the callback-to-async bridge for a single OCR request.
///
/// Vision can report a request failure through `VNRecognizeTextRequest`'s completion handler and
/// then rethrow that same failure from `VNImageRequestHandler.perform(_:)`. Swift checked
/// continuations must resume exactly once, so both paths share this short-lived gate.
private final class OCRContinuationResumer {
    private let lock = NSLock()
    private var hasResumed = false

    func resume(_ action: () -> Void) {
        lock.lock()
        let shouldResume = !hasResumed
        if shouldResume {
            hasResumed = true
        }
        lock.unlock()

        guard shouldResume else { return }
        action()
    }
}

/// A task cancellation can arrive before Vision is installed or while perform() is running.
/// The lock protects that handoff only; native cancellation runs outside it. One instance belongs
/// to one extraction, so replacing a reading query cannot cancel autocomplete's separate request.
private final class OCRRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var cancelled = false
    func install(_ request: VNRecognizeTextRequest) -> Bool {
        lock.lock()
        let allowed = !cancelled
        if allowed { self.request = request }
        lock.unlock()
        if !allowed { request.cancel() }
        return allowed
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let request = request
        lock.unlock()
        request?.cancel()
    }
}

struct ScreenTextExtractor: ScreenTextExtracting {
    /// Vision cannot produce useful text from near-zero-sized request images. Treating those as
    /// empty OCR keeps degenerate screenshots on the same unavailable-context path as blank windows.
    private static let minimumOCRImageDimension = 4

    let maxImageDimension: Int
    let maxRecognizedCharacters: Int
    var capturesWordBounds = false
    var minimumTextHeight: Float = 0.008
    var logsTextPreview = true
    var detectsLanguageAutomatically = false

    init(
        maxImageDimension: Int = VisualContextConfiguration.default.maxImageDimension,
        maxRecognizedCharacters: Int = VisualContextConfiguration.default.maxRecognizedCharacters
    ) {
        self.maxImageDimension = maxImageDimension
        self.maxRecognizedCharacters = maxRecognizedCharacters
    }

    /// Performs OCR asynchronously so the main actor is not blocked by Vision processing.
    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        let startedAt = Date()
        // Resizing a full Retina window is CPU work too; do not do it on the caller's main actor.
        let preparedImage = await Task.detached(priority: .utility) {
            downsampledImageIfNeeded(image)
        }.value
        try Task.checkCancellation()
        let wasDownsampled = preparedImage.width != image.width || preparedImage.height != image.height

        log(
            "ocr-start input=\(image.width)x\(image.height) prepared=\(preparedImage.width)x\(preparedImage.height) " +
                "downsampled=\(wasDownsampled)"
        )

        guard preparedImage.width >= Self.minimumOCRImageDimension,
              preparedImage.height >= Self.minimumOCRImageDimension else {
            log(
                "ocr-skipped-too-small input=\(image.width)x\(image.height) " +
                    "prepared=\(preparedImage.width)x\(preparedImage.height)"
            )
            throw ScreenTextExtractionError.noRecognizedText
        }

        let cancellation = OCRRequestCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: ExtractedScreenText = try await withCheckedThrowingContinuation { continuation in
            let resumer = OCRContinuationResumer()

            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        resumer.resume {
                            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                            self.log("ocr-failed elapsed_ms=\(elapsedMilliseconds) reason=\(error.localizedDescription)")
                            continuation.resume(
                                throwing: ScreenTextExtractionError.ocrFailed(error.localizedDescription)
                            )
                        }
                        return
                    }

                    let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                    // Keep each line's confidence (from its top candidate) so the hygiene pass can drop
                    // the recognizer's weakest guesses; the joined `text` below is for logging and the
                    // window-title fallback only.
                    let recognizedLines: [OCRTextHygiene.OCRLine] = observations
                        .sorted {
                            if Swift.abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.02 {
                                return $0.boundingBox.minY > $1.boundingBox.minY
                            }

                            return $0.boundingBox.minX < $1.boundingBox.minX
                        }
                        .compactMap { observation -> OCRTextHygiene.OCRLine? in
                            guard let candidate = observation.topCandidates(1).first else { return nil }
                            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return nil }
                            return OCRTextHygiene.OCRLine(
                                text: trimmed, confidence: candidate.confidence, boundingBox: observation.boundingBox
                            )
                        }

                    let joinedText = recognizedLines.map(\.text).joined(separator: "\n")
                    let cappedText = String(joinedText.prefix(maxRecognizedCharacters))
                    let words: [ScreenTextWord] = capturesWordBounds ? observations.flatMap { observation in
                        guard let candidate = observation.topCandidates(1).first else { return [ScreenTextWord]() }
                        let tokenizer = NLTokenizer(unit: .word)
                        tokenizer.string = candidate.string
                        var result: [ScreenTextWord] = []
                        tokenizer.enumerateTokens(in: candidate.string.startIndex..<candidate.string.endIndex) { range, _ in
                            if let box = try? candidate.boundingBox(for: range) {
                                result.append(ScreenTextWord(text: String(candidate.string[range]), boundingBox: box.boundingBox))
                            }
                            return true
                        }
                        return result
                    } : []

                    guard !cappedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        resumer.resume {
                            let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                            self.log("ocr-empty elapsed_ms=\(elapsedMilliseconds) lines=\(recognizedLines.count)")
                            continuation.resume(throwing: ScreenTextExtractionError.noRecognizedText)
                        }
                        return
                    }

                    resumer.resume {
                        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                        self.log(
                            "ocr-success elapsed_ms=\(elapsedMilliseconds) lines=\(recognizedLines.count) chars=\(cappedText.count) " +
                                "preview=\(self.logsTextPreview ? self.preview(cappedText) : "<omitted>")"
                        )

                        continuation.resume(
                            returning: ExtractedScreenText(
                                text: cappedText,
                                lineCount: recognizedLines.count,
                                lines: recognizedLines, words: words
                            )
                        )
                    }
                }

                // Accurate OCR is slower, but visual context refresh is throttled independently
                // of typing and the result can materially improve autocomplete relevance. Language
                // correction is on for the same reason: it cuts garbled recognitions at the
                // source, which matters because this text conditions the prompt and the
                // downstream hygiene filters can only drop junk, not repair it.
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.minimumTextHeight = minimumTextHeight
                request.automaticallyDetectsLanguage = detectsLanguageAutomatically

                guard cancellation.install(request) else {
                    resumer.resume { continuation.resume(throwing: CancellationError()) }
                    return
                }

                do {
                    let handler = VNImageRequestHandler(cgImage: preparedImage, options: [:])
                    try handler.perform([request])
                } catch {
                    resumer.resume {
                        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                        self.log("ocr-failed elapsed_ms=\(elapsedMilliseconds) reason=\(error.localizedDescription)")
                        continuation.resume(
                            throwing: ScreenTextExtractionError.ocrFailed(error.localizedDescription)
                        )
                    }
                }
            }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Keeps OCR latency bounded on very large Retina windows by scaling the image to a reasonable
    /// max dimension before text recognition.
    nonisolated private func downsampledImageIfNeeded(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let largestDimension = max(width, height)

        guard largestDimension > maxImageDimension else {
            return image
        }

        let scale = CGFloat(maxImageDimension) / CGFloat(largestDimension)
        let targetWidth = max(Int(CGFloat(width) * scale), 1)
        let targetHeight = max(Int(CGFloat(height) * scale), 1)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    private func log(_ message: String) {
        // OCR log messages include preview text from the user's screen. Route them through
        // the debug gate so they only appear when the developer explicitly opts in.
        CotabbyDebugOptions.log(message)
    }

    private func preview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 80 {
            return compact
        }

        let cut = compact.index(compact.startIndex, offsetBy: 80)
        return "\(compact[..<cut])..."
    }
}
