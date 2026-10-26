import CoreGraphics
import Foundation

/// Text-only output shared by context hygiene and reading. Confidence and normalized word
/// rectangles retain Vision's meaning; a screenshot never becomes part of a model request.
nonisolated struct ExtractedScreenText: Sendable {
    let text: String
    let lineCount: Int
    let lines: [OCRTextHygiene.OCRLine]
    let words: [ScreenTextWord]

    init(text: String, lineCount: Int, lines: [OCRTextHygiene.OCRLine] = [], words: [ScreenTextWord] = []) {
        self.text = text
        self.lineCount = lineCount
        self.lines = lines
        self.words = words
    }
}

/// Only explicit pointer queries request word boxes. Ordinary context extraction avoids the
/// helper's tokenization and per-word geometry work.
nonisolated struct ScreenTextWord: Sendable {
    let text: String
    let boundingBox: CGRect
    /// Exact offset into the emitted line, preserving repeated words without string search.
    var lineIndex: Int?
    var utf16Location: Int?
    var utf16Length: Int?
    var confidence: Float?
}

/// Keeps context hygiene tests independent of Vision, Screen Recording, and real pixels.
protocol ScreenTextExtracting {
    func extractText(from image: CGImage) async throws -> ExtractedScreenText
}

nonisolated enum ScreenTextExtractionError: LocalizedError {
    case noRecognizedText
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecognizedText: String(localized: "No usable visible text was recognized in the screenshot.")
        case let .ocrFailed(message): String(localized: "Screenshot OCR failed: \(message)")
        }
    }
}

/// A request/result adapter borrowing the app-owned runtime. It owns no queue or native request,
/// so background context and reading obey the same admission limit. The runtime handles image
/// preparation, deadlines and process recovery before this converts values for existing callers.
struct ScreenTextExtractor: ScreenTextExtracting {
    let runtime: OCRRuntime
    let maxImageDimension: Int
    let maxRecognizedCharacters: Int
    var capturesWordBounds = false
    var minimumTextHeight: Float = 0.008
    var logsTextPreview = true
    var detectsLanguageAutomatically = false
    var purpose = OCRRequestPurpose.visualContext
    var deadline: TimeInterval?

    init(runtime: OCRRuntime,
         maxImageDimension: Int = VisualContextConfiguration.default.maxImageDimension,
         maxRecognizedCharacters: Int = VisualContextConfiguration.default.maxRecognizedCharacters) {
        self.runtime = runtime
        self.maxImageDimension = maxImageDimension
        self.maxRecognizedCharacters = maxRecognizedCharacters
    }

    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        try Task.checkCancellation()
        let started = ProcessInfo.processInfo.systemUptime
        LingroveDebugOptions.log("ocr-start input=\(image.width)x\(image.height)")
        let options = OCRRequestOptions(maxImageDimension: maxImageDimension,
            maxRecognizedCharacters: maxRecognizedCharacters, capturesWordBounds: capturesWordBounds,
            minimumTextHeight: minimumTextHeight, detectsLanguageAutomatically: detectsLanguageAutomatically,
            purpose: purpose, deadline: deadline)
        let response: OCRWorkerResponse
        do {
            response = try await runtime.recognize(image, options: options)
        } catch OCRRuntimeFailure.noRecognizedText {
            throw ScreenTextExtractionError.noRecognizedText
        } catch let error as OCRRuntimeFailure {
            let message: String
            switch error {
            case .timedOut:
                message = String(localized: "Screen text recognition timed out.", table: "Learning")
            case .unavailable, .shuttingDown:
                message = String(localized: "Screen text recognition is temporarily unavailable. Try again shortly.", table: "Learning")
            default:
                message = String(localized: "Screen text recognition failed.", table: "Learning")
            }
            throw ScreenTextExtractionError.ocrFailed(message)
        }
        try Task.checkCancellation()
        if response.failure == "no-text" { throw ScreenTextExtractionError.noRecognizedText }
        if response.failure != nil {
            throw ScreenTextExtractionError.ocrFailed(String(localized: "Screen text recognition failed.", table: "Learning"))
        }
        let lines = response.lines.map {
            OCRTextHygiene.OCRLine(text: $0.text, confidence: $0.confidence, boundingBox: $0.boundingBox)
        }
        let text = String(lines.map(\.text).joined(separator: "\n").prefix(maxRecognizedCharacters))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScreenTextExtractionError.noRecognizedText
        }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
        let preview = logsTextPreview ? String(text.replacingOccurrences(of: "\n", with: " ").prefix(80)) : "<omitted>"
        LingroveDebugOptions.log("ocr-success elapsed_ms=\(elapsed) lines=\(lines.count) chars=\(text.count) preview=\(preview)")
        return ExtractedScreenText(text: text, lineCount: lines.count, lines: lines,
            words: response.words.map { ScreenTextWord(text: $0.text, boundingBox: $0.boundingBox, lineIndex: $0.lineIndex,
                utf16Location: $0.utf16Location, utf16Length: $0.utf16Length, confidence: $0.confidence) })
    }
}
