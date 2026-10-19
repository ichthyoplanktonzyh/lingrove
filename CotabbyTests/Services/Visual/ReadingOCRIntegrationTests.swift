import AppKit
import Testing

@testable import Cotabby

/// Real Vision recognition uses a generated image, so target/word-box acceptance needs neither
/// Screen Recording nor another app's private content. These are integration tests, not mocks.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct ReadingOCRIntegrationTests {
    @Test func automaticallyRecognizesChineseWithoutAUserSelectedOCRLanguage() async throws {
        let image = NSImage(size: NSSize(width: 900, height: 160))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 900, height: 160)).fill()
        ("你好，欢迎学习中文。" as NSString).draw(at: NSPoint(x: 25, y: 65), withAttributes: [
            .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black
        ])
        image.unlockFocus()
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var extractor = ScreenTextExtractor(maxImageDimension: max(cgImage.width, cgImage.height), maxRecognizedCharacters: 1)
        extractor.detectsLanguageAutomatically = true
        extractor.minimumTextHeight = 0
        extractor.logsTextPreview = false
        let result = try await extractor.extractText(from: cgImage)
        #expect(try LearningReadingTextPolicy.text(from: result.lines).contains("欢迎学习中文"))
    }

    @Test func uncappedLinesAndPointedWordBoxesSurviveContextTextCap() async throws {
        let image = NSImage(size: NSSize(width: 900, height: 220))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 900, height: 220)).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black,
        ]
        ("Please keep me posted on the progress." as NSString).draw(
            at: NSPoint(x: 25, y: 130), withAttributes: attributes)
        ("This is a second complete line." as NSString).draw(
            at: NSPoint(x: 25, y: 65), withAttributes: attributes)
        image.unlockFocus()
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var extractor = ScreenTextExtractor(
            maxImageDimension: max(cgImage.width, cgImage.height), maxRecognizedCharacters: 1)
        extractor.minimumTextHeight = 0
        extractor.capturesWordBounds = true
        extractor.logsTextPreview = false
        let result = try await extractor.extractText(from: cgImage)
        #expect(result.text.count == 1)
        let target = try LearningReadingTextPolicy.text(from: result.lines)
        #expect(target.contains("Please keep me posted on the progress."))
        #expect(target.contains("This is a second complete line."))
        let word = try #require(result.words.first { $0.text == "posted" })
        #expect(word.boundingBox.width > 0 && word.boundingBox.height > 0)
        #expect(
            result.lines.contains {
                $0.boundingBox?.contains(CGPoint(x: word.boundingBox.midX, y: word.boundingBox.midY))
                    == true
            })
    }

    @Test func cancelledOCRCannotReturnAUsableTarget() async throws {
        let image = NSImage(size: NSSize(width: 300, height: 100))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 300, height: 100)).fill()
        image.unlockFocus()
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let task = Task { try await ScreenTextExtractor().extractText(from: cgImage) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled extraction returned text")
        } catch is CancellationError {} catch { Issue.record("Expected cancellation, got \(error)") }
    }
}
