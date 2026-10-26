import AppKit
import Testing

@testable import Lingrove

/// Native Vision cases use rendered fixtures with a known pointer position. They measure OCR
/// acquisition independently of AX and a model, including columns, small text and cropped context.
/// These controlled images supplement (not replace) real-application screenshot acceptance.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct ReadingOCRQualityTests {
    @Test(arguments: ["linked-history", "wrapped", "inline-wrap", "columns", "small", "mixed", "cropped", "table", "repeated"])
    func primaryVisualRouteReadsTheSameFrozenPixels(_ name: String) async throws {
        let runtime = OCRRuntime()
        defer { runtime.shutdown() }
        let fixture = makeFixture(name)
        let bounds = CGRect(x: -1000, y: 900, width: 1000, height: 320)
        let pointer = CGPoint(x: bounds.minX + fixture.pointer.x * bounds.width,
            y: bounds.minY + fixture.pointer.y * bounds.height)
        var captures = 0
        let reader = LearningReadingVisualReader(runtime: runtime, capture: { _, _ in captures += 1; return fixture.image })
        let result = try await reader.read(at: pointer, bounds: bounds, validate: { true })
        #expect(captures == 1 && (1...2).contains(result.passes))
        if name == "table" {
            // Vision gives OpenAI and compatible the same box on this font. Retain the entire
            // hyphenated unit rather than claiming that geometry identified one of its parts.
            #expect(result.text.lowercased().hasSuffix("-compatible"))
        } else { #expect(result.text.lowercased() == fixture.target) }
        #expect(result.anchor.insetBy(dx: -3, dy: -3).contains(pointer))
        let context = try #require(result.context)
        #expect((context.text as NSString).substring(with: context.target) == result.text)
        #expect(!context.text.contains("Unrelated sidebar"))
        if name == "linked-history" { #expect(context.text.contains("Preview") && context.text.contains("AnkiConnect")) }
        if name == "cropped" { #expect(!context.isComplete) }
        if name == "table" { #expect(context.text.contains("-compatible chat endpoint") && !context.text.contains("Different cell")) }
        if name == "repeated" { #expect(context.text.contains("river") && !context.text.contains("approved")) }
        print("READING_OCR_PRIMARY \(name): passes=\(result.passes), target=\(result.text), context=\(context.text)")
    }

    @Test(arguments: ["linked-history", "wrapped", "inline-wrap", "columns", "small", "mixed", "cropped"])
    func capturesTargetAndContextFromPixels(_ name: String) async throws {
        let runtime = OCRRuntime()
        defer { runtime.shutdown() }
        let fixture = makeFixture(name)
        var extractor = ScreenTextExtractor(runtime: runtime,
            maxImageDimension: max(fixture.image.width, fixture.image.height), maxRecognizedCharacters: 1)
        extractor.minimumTextHeight = 0
        extractor.capturesWordBounds = true
        extractor.detectsLanguageAutomatically = true
        extractor.logsTextPreview = false
        let result = try await extractor.extractText(from: fixture.image)
        let word = try #require(result.words.first { $0.boundingBox.contains(fixture.pointer) })
        #expect(word.text.lowercased() == fixture.target)
        let context = try #require(LearningReadingOCRPolicy.context(word: word, lines: result.lines,
            imageSize: CGSize(width: fixture.image.width, height: fixture.image.height)))
        #expect((context.text as NSString).substring(with: context.target).lowercased() == fixture.target)
        #expect(!context.text.contains("Unrelated sidebar"))
        if name == "linked-history" { #expect(context.text.contains("Preview") && context.text.contains("AnkiConnect")) }
        if name == "inline-wrap" { #expect(context.text.contains("remain part of a single thought")) }
        if name == "wrapped" { #expect(context.text.contains("single sentence")) }
        if name == "columns" || name == "small" { #expect(context.text.contains("Keep your review")) }
        if name == "cropped" { #expect(!context.isComplete, "A screenshot cannot recover the invisible beginning") }
        print("READING_OCR_CASE \(name): target=\(word.text), complete=\(context.isComplete), context=\(context.text)")
    }

    private func makeFixture(_ name: String) -> (image: CGImage, pointer: CGPoint, target: String) {
        let font = NSFont.systemFont(ofSize: name == "small" ? 11 : 20)
        let selected: String
        switch name {
        case "inline-wrap": selected = "styled"
        case "table": selected = "compatible"
        case "repeated": selected = "bank"
        default: selected = "history"
        }
        let lines: [String]
        switch name {
        case "linked-history":
            lines = ["Preview recognition and cloze/gap cards, attach generated TTS audio,",
                     "and send or batch-update notes directly to Anki Desktop via",
                     "AnkiConnect while preserving your review history."]
        case "wrapped":
            lines = ["We keep this entire single sentence on several styled lines",
                     "that preserve your review history for a later reading session."]
        case "inline-wrap":
            lines = ["We keep this entire sentence on", "several styled lines that remain", "part of a single thought."]
        case "mixed": lines = ["我们正在学习英文。Keep your review history safe."]
        case "cropped": lines = ["while preserving your review history."]
        case "table": lines = ["OpenAI-compatible chat endpoint"]
        case "repeated": lines = ["The bank approved a loan. We sat on the bank of the river. Another sentence."]
        default: lines = ["An earlier sentence. Keep your review", "history safe. Another sentence follows."]
        }
        let size = CGSize(width: 1000, height: 320)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        var pointer = CGPoint.zero
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        for (index, line) in lines.enumerated() {
            let origin = CGPoint(x: 24, y: 240 - CGFloat(index) * (font.pointSize * 1.6))
            let text = NSMutableAttributedString(string: line, attributes: attributes)
            let link = (line as NSString).range(of: "AnkiConnect")
            if link.location != NSNotFound { text.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: link) }
            text.draw(at: origin)
            let target = (line as NSString).range(of: selected, options: .backwards)
            if target.location != NSNotFound {
                let prefixWidth = ((line as NSString).substring(to: target.location) as NSString).size(withAttributes: attributes).width
                let wordWidth = (selected as NSString).size(withAttributes: attributes).width
                pointer = CGPoint(x: (origin.x + prefixWidth + wordWidth / 2) / size.width,
                    y: (origin.y + font.pointSize * 0.6) / size.height)
            }
            if name == "columns" {
                ("Unrelated sidebar navigation." as NSString).draw(at: CGPoint(x: 600, y: origin.y - 4), withAttributes: attributes)
            }
            if name == "table" {
                ("Different cell" as NSString).draw(at: CGPoint(x: 700, y: origin.y), withAttributes: attributes)
            }
        }
        image.unlockFocus()
        // A test-owned image with a valid drawing context always has a CGImage representation.
        return (image.cgImage(forProposedRect: nil, context: nil, hints: nil)!, pointer, selected)
    }
}
