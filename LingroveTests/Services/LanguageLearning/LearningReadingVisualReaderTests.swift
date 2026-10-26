import CoreGraphics
import Foundation
import Testing
@testable import Lingrove

/// These tests cross the production visual reader's capture/recognition seam. The source image
/// is deterministic; fake OCR allows cancellation, timeout and occurrence conflicts to be forced.
@MainActor
struct LearningReadingVisualReaderTests {
    private let bounds = CGRect(x: -1000, y: 900, width: 1000, height: 600)
    private let pointer = CGPoint(x: -500, y: 1200)

    @Test func pointerRoutePrefersOCRAndRetainsAXWhenCaptureIsUnavailableOrFails() async throws {
        let hit = LearningReadingSourceReader.PointedText(text: "history", anchor: .zero, hint: nil, context: nil)
        var axCalls = 0
        let fallback = { axCalls += 1; return Optional(hit) }
        _ = try await LearningReadingSourceReader.capturePointer(visual: { hit }, fallback: fallback, validate: { true })
        #expect(axCalls == 0)
        _ = try await LearningReadingSourceReader.capturePointer(visual: nil, fallback: fallback, validate: { true })
        #expect(axCalls == 1)
        _ = try await LearningReadingSourceReader.capturePointer(visual: { throw OCRRuntimeFailure.unavailable },
            fallback: fallback, validate: { true })
        #expect(axCalls == 2)
    }

    @Test func cancelledOrStaleOCRCannotFallThroughToAX() async {
        var axCalls = 0, current = true
        let fallback: () -> LearningReadingSourceReader.PointedText? = { axCalls += 1; return nil }
        await #expect(throws: CancellationError.self) {
            try await LearningReadingSourceReader.capturePointer(visual: { throw CancellationError() },
                fallback: fallback, validate: { current })
        }
        await #expect(throws: CancellationError.self) {
            try await LearningReadingSourceReader.capturePointer(visual: { current = false; throw OCRRuntimeFailure.unavailable },
                fallback: fallback, validate: { current })
        }
        #expect(axCalls == 0)
    }

    @Test func expansionUsesOneFrameOneDeadlineAndTheSameOccurrence() async throws {
        var captures = 0, sizes: [CGSize] = [], deadlines: [TimeInterval] = []
        let reader = LearningReadingVisualReader(capture: { rect, _ in
            captures += 1; #expect(rect == bounds); return try image()
        }, extract: { image, deadline in
            sizes.append(CGSize(width: image.width, height: image.height)); deadlines.append(deadline)
            return extraction(expanded: sizes.count == 2, size: sizes.last!)
        }, now: { 100 })
        let result = try await reader.read(at: pointer, bounds: bounds, validate: { true })
        #expect(captures == 1 && result.passes == 2)
        #expect(sizes == [CGSize(width: 720, height: 240), CGSize(width: 1000, height: 600)])
        #expect(deadlines == [112, 112])
        #expect(result.text == "history" && result.context?.text.trimmingCharacters(in: .whitespacesAndNewlines) == "We preserve your history.")
        #expect(result.context?.isComplete == true)
        #expect(result.anchor.contains(pointer))
    }

    @Test func clippedFirstPassCanRecoverButAnInteriorFragmentDoesNotExpand() async throws {
        var calls = 0
        let reader = LearningReadingVisualReader(capture: { _, _ in try image() }, extract: { image, _ in
            calls += 1
            if calls == 1 { throw ScreenTextExtractionError.noRecognizedText }
            return extraction(expanded: true, size: CGSize(width: image.width, height: image.height))
        })
        #expect(try await reader.read(at: pointer, bounds: bounds, validate: { true }).passes == 2)
        let fragment = LearningReadingVisualReader(capture: { _, _ in try image() }, extract: { image, _ in
            extraction(expanded: false, size: CGSize(width: image.width, height: image.height), touchesEdge: false)
        })
        let result = try await fragment.read(at: pointer, bounds: bounds, validate: { true })
        #expect(result.passes == 1 && result.context?.isComplete == false)
    }

    @Test func expirationOrFailedExpansionKeepsTheEarlierHonestFragment() async throws {
        for expire in [false, true] {
            var calls = 0, clock: TimeInterval = 0
            let reader = LearningReadingVisualReader(capture: { _, _ in try image() }, extract: { image, _ in
                calls += 1
                if calls == 2 { throw OCRRuntimeFailure.timedOut }
                if expire { clock = 13 }
                return extraction(expanded: false, size: CGSize(width: image.width, height: image.height))
            }, now: { clock })
            let result = try await reader.read(at: pointer, bounds: bounds, validate: { true })
            #expect(result.text == "history" && result.context?.isComplete == false)
            #expect(calls == (expire ? 1 : 2))
        }
    }

    @Test func invalidationAfterCaptureOrRecognitionNeverPublishesOrRetries() async throws {
        for atCapture in [false, true] {
            var current = true, calls = 0
            let reader = LearningReadingVisualReader(capture: { _, _ in
                if atCapture { current = false }; return try image()
            }, extract: { image, _ in
                calls += 1; current = false
                return extraction(expanded: false, size: CGSize(width: image.width, height: image.height))
            })
            await #expect(throws: CancellationError.self) {
                try await reader.read(at: pointer, bounds: bounds, validate: { current })
            }
            #expect(calls == (atCapture ? 0 : 1))
        }
    }

    @Test func cancellationDuringExpansionCannotReturnTheFirstPass() async throws {
        var calls = 0
        let reader = LearningReadingVisualReader(capture: { _, _ in try image() }, extract: { image, _ in
            calls += 1
            if calls == 2 { throw CancellationError() }
            return extraction(expanded: false, size: CGSize(width: image.width, height: image.height))
        })
        await #expect(throws: CancellationError.self) { try await reader.read(at: pointer, bounds: bounds, validate: { true }) }
        #expect(calls == 2)
    }

    private func image() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1000, height: 600, bitsPerComponent: 8, bytesPerRow: 4000,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }

    private func extraction(expanded: Bool, size: CGSize, touchesEdge: Bool = true) -> ExtractedScreenText {
        let text = expanded ? "Earlier sentence. We preserve your history. Another sentence." : "while preserving your history."
        let offset = (text as NSString).range(of: "history")
        let width = expanded || !touchesEdge ? 0.8 : 1.0
        return .init(text: text, lineCount: 1,
            lines: [.init(text: text, confidence: 1, boundingBox: CGRect(x: (1 - width) / 2, y: 0.48, width: width, height: 0.04))],
            words: [.init(text: "history", boundingBox: CGRect(x: 0.5 - 20 / size.width, y: 0.5 - 10 / size.height,
                width: 40 / size.width, height: 20 / size.height), lineIndex: 0,
                utf16Location: offset.location, utf16Length: offset.length, confidence: 1)])
    }
}
