import AppKit
import Testing
@testable import Lingrove

/// Committed browser pixels lock down acquisition independently of a live page, AX permissions,
/// or a language model. The manifest stores DOM-measured target geometry; OCR cannot define its
/// own expected location. Each route still uses the production frozen-frame reader and worker.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ReadingOCRFixtureTests {
    private struct Point: Decodable { let x: Double; let y: Double }
    private struct Fixture: Decodable {
        let name: String
        let width: Double
        let height: Double
        let x: Double
        let y: Double
        let target: String
        let selectionWidth: Double
        let selectionHeight: Double
        let dragStart: Point?
        let dragEnd: Point?
    }

    @Test func fixedBrowserSelectionsRetainTheirTargetsAndLocalContext() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Reading/Screenshots")
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let runtime = OCRRuntime()
        defer { runtime.shutdown() }
        var cases = 0
        for fixture in fixtures {
            let image = try #require(NSImage(contentsOf: directory.appendingPathComponent(fixture.name + ".png")))
            let pixels = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let viewport = CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height)
            let point = CGPoint(x: fixture.x, y: fixture.height - fixture.y)
            let selected = CGRect(x: point.x - fixture.selectionWidth / 2, y: point.y - fixture.selectionHeight / 2,
                width: fixture.selectionWidth, height: fixture.selectionHeight)
            let bounds = try #require(LearningReadingVisualPolicy.snapshotBounds(at: point, screen: viewport,
                window: viewport, scale: CGFloat(pixels.width) / viewport.width))
            let crop = LearningReadingVisualPolicy.crop(bounds, frame: viewport, pixels: CGSize(width: pixels.width, height: pixels.height))
            let frame = try #require(pixels.cropping(to: crop.pixels))
            // A compound's shared OCR word box cannot prove a subword drag, and the older
            // multiline fixture has only its union box. Their exact AX route remains covered.
            let modes = ["table", "multiline"].contains(fixture.name) ? ["ax"] : ["ax", "forward", "backward"]
            for mode in modes {
                var capture = LearningReadingSelection(id: UUID(), text: fixture.target, processIdentifier: 1,
                    bundleIdentifier: "browser.fixture", anchor: CGRect(origin: point, size: CGSize(width: 1, height: 18)))
                if mode == "ax" { capture.selectionBounds = selected } else {
                    let start = fixture.dragStart.map { CGPoint(x: $0.x, y: fixture.height - $0.y) }
                        ?? CGPoint(x: selected.maxX, y: selected.midY)
                    let end = fixture.dragEnd.map { CGPoint(x: $0.x, y: fixture.height - $0.y) }
                        ?? CGPoint(x: selected.minX, y: selected.midY)
                    capture.gesture = .init(selectionID: capture.id, start: mode == "backward" ? start : end,
                        end: mode == "backward" ? end : start, kind: .drag, completedAt: capture.capturedAt)
                }
                var captures = 0
                let reader = LearningReadingVisualReader(runtime: runtime, capture: { _, _ in captures += 1; return frame })
                let resolution = try await reader.resolveSelection(capture, bounds: bounds,
                    deadline: ProcessInfo.processInfo.systemUptime + 12, validate: { true })
                let result = try #require(resolution.result, "\(fixture.name)/\(mode): \(resolution.reason)")
                let context = try #require(result.context)
                #expect(captures == 1 && (1...2).contains(result.passes))
                #expect(result.text == fixture.target)
                #expect((context.window.text as NSString).substring(with: context.window.target) == fixture.target)
                #expect(!context.text.contains("Reading fixture") && !context.text.contains("Select target"))
                if fixture.name == "history" { #expect(context.text.contains("Preview") && context.text.contains("AnkiConnect")) }
                if fixture.name == "columns" || fixture.name == "narrow-columns" { #expect(!context.text.contains("Unrelated")) }
                if fixture.name == "repeated" { #expect(context.text.contains("river") && !context.text.contains("approved")) }
                if fixture.name == "table" { #expect(!context.text.contains("Speech") && !context.text.contains("another row")) }
                if fixture.name == "cropped" { #expect(!context.isComplete && !context.text.contains("hidden main clause")) }
                if fixture.name == "tall-emphasis" || fixture.name == "narrow-columns" {
                    #expect(context.text.contains("Keep your") && context.text.contains("safe."))
                }
                cases += 1
                print("READING_FIXED_FIXTURE \(fixture.name)/\(mode): \(resolution.reason) passes=\(result.passes) context=\(context.text)")
            }
        }
        #expect(cases == 29)
    }
}
