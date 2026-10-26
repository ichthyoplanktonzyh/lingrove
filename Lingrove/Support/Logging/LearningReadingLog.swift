import Foundation
import Logging

/// One content-free diagnostic vocabulary for acquisition and routing. Callers retain their
/// existing request task-local; only reason codes, sizes and methods enter the ordinary log.
/// Model prompts, selected words and native localized errors must not be copied into these events.
nonisolated enum LearningReadingLog {
    enum Stage: String { case axSelection, axRange, axMarkers, axBlock, selectionGeometry, selectionOCR, pointerOCR, routing }

    static func emit(_ stage: Stage, _ reason: String, details: [String: String] = [:], requestID: String? = nil) {
        var metadata: Logger.Metadata = [
            "request_id": .string(requestID ?? LearningRequestTrace.requestID ?? "unscoped"),
            "stage": .string(stage.rawValue), "reason": .string(reason)
        ]
        for (key, value) in details { metadata[key] = .string(value) }
        LingroveLogger.learning.debug("Reading acquisition decision", metadata: metadata)
    }

    static func failure(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? LearningReadingVisualReader.Failure {
            switch error {
            case .noTarget: return "no-spatial-target"
            case .invalidFrame: return "invalid-frame"
            }
        }
        if let error = error as? OCRRuntimeFailure { return "ocr-" + error.rawValue }
        if let error = error as? ScreenTextExtractionError {
            switch error {
            case .noRecognizedText: return "ocr-no-text"
            case .ocrFailed: return "ocr-failed"
            }
        }
        if let error = error as? WindowScreenshotError { return screenshotFailure(error) }
        return "unclassified-failure"
    }

    private static func screenshotFailure(_ error: WindowScreenshotError) -> String {
        switch error {
        case .screenRecordingPermissionMissing: return "screen-permission-missing"
        case .noVisibleWindowForProcess: return "window-unavailable"
        case .captureFailed: return "capture-failed"
        }
    }
}
