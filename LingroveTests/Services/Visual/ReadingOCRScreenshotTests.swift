import AppKit
import Testing
@testable import Lingrove

/// Opt-in pixel replay of the repository's browser fixture, captured through the browser tool.
/// No user page or live desktop is read by this test. Release runs may report acquisition timings.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ReadingOCRScreenshotTests {
    private struct Fixture: Decodable {
        let name: String
        let width: Double
        let height: Double
        let x: Double
        let y: Double
        let target: String
    }

    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_OCR_SCREENSHOTS"] != nil))
    func replaysBrowserPixelsThroughThePrimaryPipeline() async throws {
        let directory = URL(fileURLWithPath: try #require(LingroveCompatibility.processEnvironment["LINGROVE_OCR_SCREENSHOTS"]))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let runtime = OCRRuntime()
        defer { runtime.shutdown() }
        for fixture in fixtures {
            let image = try #require(NSImage(contentsOf: directory.appendingPathComponent(fixture.name + ".png")))
            let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let viewport = CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height)
            let point = CGPoint(x: fixture.x, y: fixture.height - fixture.y)
            let bounds = try #require(LearningReadingVisualPolicy.snapshotBounds(at: point, screen: viewport,
                window: viewport, scale: CGFloat(pixels.width) / viewport.width))
            let crop = LearningReadingVisualPolicy.crop(bounds, frame: viewport, pixels: CGSize(width: pixels.width, height: pixels.height))
            let snapshot = try #require(pixels.cropping(to: crop.pixels))
            var captures = 0
            let reader = LearningReadingVisualReader(runtime: runtime, capture: { _, _ in captures += 1; return snapshot })
            let started = ProcessInfo.processInfo.systemUptime
            let result = try await reader.read(at: point, bounds: bounds, validate: { true })
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            #expect(captures == 1 && result.text.lowercased().contains(fixture.target.lowercased()))
            let context = try #require(result.context)
            #expect(!context.text.contains("Reading fixture"), "The neighbouring heading is not sentence context")
            #expect((context.text as NSString).substring(with: context.target) == result.text)
            if fixture.name == "history" { #expect(context.text.contains("Preview") && context.text.contains("AnkiConnect")) }
            if fixture.name == "columns" { #expect(!context.text.contains("Unrelated") && !context.text.contains("second column")) }
            if fixture.name == "table" { #expect(!context.text.contains("Speech") && !context.text.contains("another row")) }
            if fixture.name == "repeated" { #expect(context.text.contains("river") && !context.text.contains("approved")) }
            if fixture.name == "cropped" { #expect(!context.isComplete && !context.text.contains("hidden main clause")) }
            print("BROWSER_OCR \(fixture.name) ms=\(elapsed) passes=\(result.passes) target=\(result.text) context=\(context.text)")
        }
    }
}
