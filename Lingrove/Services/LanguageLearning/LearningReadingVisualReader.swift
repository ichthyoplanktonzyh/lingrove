import CoreGraphics
import Foundation

/// The app-owned reading adapter borrows this module for one operation. A single captured image
/// supplies at most two OCR crops; only text and geometry leave the operation. Injected capture
/// and recognition closures let lifecycle tests exercise the real flow without another app.
@MainActor
struct LearningReadingVisualReader {
    struct Result {
        let text: String
        let anchor: CGRect
        let context: LearningReadingContext?
        let capturedAt: Date
        let passes: Int
    }

    enum Failure: Error { case noTarget, invalidFrame }
    private struct Candidate {
        let word: ScreenTextWord
        let anchor: CGRect
        let block: LearningReadingOCRPolicy.Block?
        let needsExpansion: Bool
    }

    private let capture: (CGRect, TimeInterval) async throws -> CGImage
    private let extract: (CGImage, TimeInterval) async throws -> ExtractedScreenText
    private let now: () -> TimeInterval

    init(runtime: OCRRuntime, capture: @escaping (CGRect, TimeInterval) async throws -> CGImage = {
        try await WindowScreenshotService().captureRegion($0, deadline: $1)
    }) {
        self.init(capture: capture, extract: { image, deadline in
            var extractor = ScreenTextExtractor(runtime: runtime,
                maxImageDimension: max(image.width, image.height), maxRecognizedCharacters: 1)
            extractor.minimumTextHeight = 0
            extractor.capturesWordBounds = true
            extractor.logsTextPreview = false
            extractor.detectsLanguageAutomatically = true
            extractor.purpose = .reading
            extractor.deadline = deadline
            return try await extractor.extractText(from: image)
        })
    }

    init(capture: @escaping (CGRect, TimeInterval) async throws -> CGImage,
         extract: @escaping (CGImage, TimeInterval) async throws -> ExtractedScreenText,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capture = capture; self.extract = extract; self.now = now
    }

    func read(at point: CGPoint, bounds: CGRect, deadline suppliedDeadline: TimeInterval? = nil,
              validate: () -> Bool) async throws -> Result {
        try checkCurrent(validate)
        guard bounds.width >= 4, bounds.height >= 4, bounds.contains(point) else { throw Failure.invalidFrame }
        let deadline = suppliedDeadline ?? now() + 12
        let image = try await capture(bounds, deadline)
        let capturedAt = Date()
        try checkCurrent(validate)
        let pixels = CGSize(width: image.width, height: image.height)
        let first = LearningReadingVisualPolicy.centered(at: point, size: LearningReadingVisualPolicy.initialSize, within: bounds)
        let regions = first == bounds ? [first] : [first, bounds]
        var accepted: Candidate?, passes = 0
        for region in regions {
            try checkCurrent(validate)
            guard now() < deadline else {
                if accepted != nil { break }
                throw OCRRuntimeFailure.timedOut
            }
            let crop = LearningReadingVisualPolicy.crop(region, frame: bounds, pixels: pixels)
            guard let cropped = image.cropping(to: crop.pixels) else { throw Failure.invalidFrame }
            passes += 1
            do {
                let extraction = try await extract(cropped, deadline)
                try checkCurrent(validate)
                if let candidate = candidate(extraction, point: point, region: crop.screen, pixels: crop.pixels.size) {
                    accepted = preferred(candidate, over: accepted)
                    if !candidate.needsExpansion { break }
                }
            } catch {
                try checkCurrent(validate)
                if try canRetry(error, hasCandidate: accepted != nil) { continue }
                break
            }
        }
        try checkCurrent(validate)
        guard let accepted else { throw Failure.noTarget }
        return Result(text: accepted.word.text, anchor: accepted.anchor, context: accepted.block?.context,
            capturedAt: capturedAt, passes: passes)
    }

    /// An explicit selection has its own geometry and exact text, so pointer hit testing is
    /// inappropriate here. Both crops align independently; no OCR text becomes the target.
    func readSelection(_ selection: LearningReadingSelection, bounds: CGRect, deadline: TimeInterval,
                       validate: () -> Bool) async throws -> Result? {
        try checkCurrent(validate)
        guard let selected = selection.selectionBounds, LearningReadingSelectionOCRPolicy.valid(selected), bounds.contains(selected)
        else { return nil }
        let image = try await capture(bounds, deadline)
        let capturedAt = Date()
        try checkCurrent(validate)
        let size = CGSize(width: image.width, height: image.height)
        let point = CGPoint(x: selected.midX, y: selected.midY)
        let first = LearningReadingVisualPolicy.centered(at: point,
            size: CGSize(width: max(720, selected.width + 56), height: max(240, selected.height + 56)), within: bounds)
        var accepted: LearningReadingSelectionOCRPolicy.Match?, passes = 0
        for region in first == bounds ? [first] : [first, bounds] {
            try checkCurrent(validate)
            guard now() < deadline else { break }
            let crop = LearningReadingVisualPolicy.crop(region, frame: bounds, pixels: size)
            guard let pixels = image.cropping(to: crop.pixels) else { throw Failure.invalidFrame }
            passes += 1
            do {
                let extraction = try await extract(pixels, deadline)
                try checkCurrent(validate)
                let alignment = LearningReadingSelectionOCRPolicy.alignment(selection, extraction: extraction,
                    region: crop.screen, pixels: crop.pixels.size)
                if case .ambiguous = alignment { return nil }
                if case .matched(let match) = alignment {
                    if let previous = accepted, !sameSelectionOccurrence(previous.targetBounds, match.targetBounds) { return nil }
                    accepted = preferredSelection(match, over: accepted)
                    if match.context.isComplete || crop.screen.insetBy(dx: 28, dy: 28).contains(match.bounds) { break }
                }
            } catch {
                try checkCurrent(validate)
                if try canRetry(error, hasCandidate: accepted != nil) { continue }
                break
            }
        }
        try checkCurrent(validate)
        return accepted.map { Result(text: selection.text, anchor: selection.anchor,
            context: $0.context, capturedAt: capturedAt, passes: passes) }
    }

    private func sameSelectionOccurrence(_ first: CGRect, _ second: CGRect) -> Bool {
        let overlap = first.intersection(second)
        let area = min(first.width * first.height, second.width * second.height)
        let distance = hypot(first.midX - second.midX, first.midY - second.midY)
        return !overlap.isNull && overlap.width * overlap.height >= area * 0.8 &&
            distance <= max(4, min(first.width, second.width) * 0.35)
    }

    private func preferredSelection(_ candidate: LearningReadingSelectionOCRPolicy.Match,
                                    over previous: LearningReadingSelectionOCRPolicy.Match?) -> LearningReadingSelectionOCRPolicy.Match {
        guard let previous else { return candidate }
        // Both are independently aligned OCR candidates. The exact AX-neighbour compatibility
        // check belongs at the final AX/OCR seam, not between two fallible OCR passes.
        if candidate.context.isComplete != previous.context.isComplete {
            return candidate.context.isComplete ? candidate : previous
        }
        return candidate.context.text.utf16.count >= previous.context.text.utf16.count ? candidate : previous
    }

    private func candidate(_ extraction: ExtractedScreenText, point: CGPoint, region: CGRect, pixels: CGSize) -> Candidate? {
        let unit = CGPoint(x: (point.x - region.minX) / region.width, y: (point.y - region.minY) / region.height)
        guard let word = LearningReadingVisualPolicy.hit(at: unit, in: extraction, pixels: pixels) else { return nil }
        let block = LearningReadingOCRPolicy.block(word: word, lines: extraction.lines, imageSize: pixels)
        let anchor = LearningReadingVisualPolicy.screenRect(word.boundingBox, in: region)
        let blockRect = block.map { LearningReadingVisualPolicy.screenRect($0.bounds, in: region) } ?? anchor
        let inside = region.insetBy(dx: 28, dy: 28)
        let needsExpansion = block?.context == nil ||
            (block?.context?.isComplete != true && !inside.contains(blockRect))
        return Candidate(word: word, anchor: anchor, block: block, needsExpansion: needsExpansion)
    }

    private func preferred(_ candidate: Candidate, over previous: Candidate?) -> Candidate {
        guard let previous else { return candidate }
        // Replace a whole result, never stitch two passes or relocate a repeated occurrence.
        guard sameTarget(previous, candidate) else { return previous }
        let context = candidate.block?.context, oldContext = previous.block?.context
        if let confidence = context?.window.confidence, let oldConfidence = oldContext?.window.confidence,
           confidence < 0.5, oldConfidence - confidence > 0.3 { return previous }
        if (context?.isComplete == true) != (oldContext?.isComplete == true) {
            return context?.isComplete == true ? candidate : previous
        }
        return (context?.text.utf16.count ?? 0) >= (oldContext?.text.utf16.count ?? 0) ? candidate : previous
    }

    private func canRetry(_ error: any Error, hasCandidate: Bool) throws -> Bool {
        if error is CancellationError { throw error }
        if hasCandidate { return false }
        // Only clipped/no-text crops benefit from expansion; a native failure leaves for AX.
        if case ScreenTextExtractionError.noRecognizedText = error { return true }
        throw error
    }

    private func sameTarget(_ first: Candidate, _ second: Candidate) -> Bool {
        let overlap = first.anchor.intersection(second.anchor)
        let area = min(first.anchor.width * first.anchor.height, second.anchor.width * second.anchor.height)
        return first.word.text.utf16.elementsEqual(second.word.text.utf16) &&
            !overlap.isNull && overlap.width * overlap.height >= area * 0.5
    }

    private func checkCurrent(_ validate: () -> Bool) throws {
        try Task.checkCancellation()
        guard validate() else { throw CancellationError() }
    }
}
