import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Cotabby

/// These fixtures own temporary notebooks, never the user's library. Assertions cross archive
/// transactions and reopen from disk, including failure paths where a JSON-only test misses data loss.
nonisolated struct VocabularyContentTests {
    private func capture() -> VocabularyCapture {
        .init(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word, meaning: "河岸")
    }

    @Test func importBoundsImageAndDoesNotWriteCancelledDrafts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = VocabularyArchive(url: folder.appendingPathComponent("notebook.sqlite"))
        let image = try await archive.prepareImage(VocabularyImageTestFixture.png(width: 2_000, height: 1_000))
        #expect(image.reference.width == 1_600 && image.reference.height == 800)
        #expect(image.data.count == image.reference.byteCount)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await #expect(throws: (any Error).self) { try await archive.prepareImage(Data("not an image".utf8)) }
    }

    @Test func imageAndTextSurviveReopenAndPortableBackupRestore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source/notebook.sqlite")
        let archive = VocabularyArchive(url: url)
        let original = try await archive.save(capture()).document.entries[0]
        let image = try await archive.prepareImage(VocabularyImageTestFixture.png())
        var edited = original
        edited.senses[0].content = [.init(content: .text(.init(text: "River bank", bold: true))),
            .init(content: .image(image.reference, caption: "河岸"))]
        let binding = AnkiNoteBinding(originSenseID: original.senses[0].id, endpoint: "http://127.0.0.1:8765", profile: "Fixture",
            noteID: 42, model: AnkiReviewPolicy.presetName, deck: "Default", identityField: "LingroveID",
            mapping: AnkiReviewPolicy.presetMapping, fields: ["LingroveID": original.senses[0].id.uuidString.lowercased()])
        _ = try await archive.update(edited, basedOn: original, importedImages: [image.reference.filename: image.data])
        _ = try await archive.saveReview(entryID: original.id, senseID: original.senses[0].id,
            value: .init(plan: .init(), bindings: [binding], activeBindingID: binding.id), expected: nil)
        let reopened = VocabularyArchive(url: url)
        #expect(try await reopened.load().document.entries[0].senses[0].content == edited.senses[0].content)
        #expect(try await reopened.image(image.reference) == image.data)
        let backup = folder.appendingPathComponent("backup.lingrove")
        try await reopened.backup(to: backup)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        let restored = VocabularyArchive(url: folder.appendingPathComponent("restored/notebook.sqlite"))
        let result = try await restored.restore(from: backup)
        #expect(result.document.entries[0].senses[0].id == original.senses[0].id)
        #expect(result.document.entries[0].senses[0].content == edited.senses[0].content)
        #expect(result.document.entries[0].senses[0].review?.activeBinding == binding)
        #expect(try await restored.image(image.reference) == image.data)
    }

    @Test func conflictCannotOverwriteContentOrWriteDraftImages() async throws {
        let archive = VocabularyArchive(url: nil)
        let original = try await archive.save(capture()).document.entries[0]
        var first = original, second = original
        first.senses[0].content = [.init(content: .text(.init(text: "First")))]
        _ = try await archive.update(first, basedOn: original)
        let image = try await archive.prepareImage(VocabularyImageTestFixture.png())
        second.senses[0].content = [.init(content: .image(image.reference, caption: ""))]
        await #expect(throws: VocabularyError.editConflict) {
            try await archive.update(second, basedOn: original, importedImages: [image.reference.filename: image.data])
        }
        await #expect(throws: (any Error).self) { try await archive.image(image.reference) }
        #expect(try await archive.load().document.entries[0].senses[0].content == first.senses[0].content)
        var noteOnly = original
        noteOnly.senses[0].note = "An independent edit"
        #expect(try await archive.update(noteOnly, basedOn: original).document.entries[0].senses[0].content == first.senses[0].content)
    }

    @Test func replacedDatabaseRejectsCommitAndRollsBackNewMedia() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: url)
        let original = try await archive.save(capture()).document.entries[0]
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let image = try await archive.prepareImage(VocabularyImageTestFixture.png())
        var edited = original
        edited.senses[0].content = [.init(content: .image(image.reference, caption: ""))]
        await #expect(throws: (any Error).self) {
            try await archive.update(edited, basedOn: original, importedImages: [image.reference.filename: image.data])
        }
        await #expect(throws: VocabularyError.self) { _ = try await archive.load() }
        let mediaURL = folder.appendingPathComponent("notebook.sqlite.media").appendingPathComponent(image.reference.filename)
        #expect(!FileManager.default.fileExists(atPath: mediaURL.path))
    }

    @Test func mergingSensesPreservesBlocksAndSharedImageUntilLastReferenceIsRemoved() async throws {
        let archive = VocabularyArchive(url: nil)
        let original = try await archive.save(capture()).document.entries[0]
        let secondID = UUID()
        let withTwo = try await archive.createSense(entryID: original.id, senseID: secondID).document.entries[0]
        let image = try await archive.prepareImage(VocabularyImageTestFixture.png())
        var edited = withTwo
        edited.senses[0].content = [.init(content: .image(image.reference, caption: "first"))]
        edited.senses[1].content = [.init(content: .image(image.reference, caption: "second"))]
        _ = try await archive.update(edited, basedOn: withTwo, importedImages: [image.reference.filename: image.data])
        let merged = try await archive.mergeSenses(entryID: original.id, source: secondID, target: original.senses[0].id)
        let blocks = try #require(merged.document.entries[0].senses[0].content)
        #expect(Set(blocks.map(\.id)) == Set(edited.senses.flatMap { $0.content ?? [] }.map(\.id)))
        #expect(try await archive.image(image.reference) == image.data)
        _ = try await archive.removeSense(entryID: original.id, senseID: original.senses[0].id)
        await #expect(throws: (any Error).self) { try await archive.image(image.reference) }
    }

    @Test func malformedOrMissingBackupMediaCannotReplaceNotebook() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = VocabularyArchive(url: nil)
        let before = try await archive.save(capture()).document
        let image = try await archive.prepareImage(VocabularyImageTestFixture.png())
        var broken = before
        broken.entries[0].senses[0].content = [.init(content: .image(image.reference, caption: ""))]
        let url = folder.appendingPathComponent("invalid.lingrove")
        for media in [[:], [image.reference.filename: Data("corrupt".utf8)], ["../outside.png": image.data]] {
            try JSONEncoder().encode(VocabularyBackup(document: broken, images: media)).write(to: url)
            await #expect(throws: (any Error).self) { try await archive.restore(from: url) }
            #expect(try await archive.load().document == before)
        }
        let invalid = VocabularyImageReference(digest: "../outside", width: 1, height: 1, byteCount: 5)
        #expect(!VocabularyContentPolicy.valid(invalid))
    }

    @Test func imageOnlyReviewHasAnswerMediaAndGapFrontNeverRevealsIt() async throws {
        let archive = VocabularyArchive(url: nil)
        var entry = try await archive.save(capture()).document.entries[0]
        let image = try await archive.prepareImage(VocabularyImageTestFixture.png())
        entry.senses[0].meaning = ""
        entry.senses[0].content = [.init(content: .image(image.reference, caption: "<river>"))]
        #expect(VocabularyPolicy.matches(entry, query: "river"))
        let plan = ReviewCardPolicy.initialPlan(entry.senses[0])
        let content = try ReviewCardPolicy.content(entry: entry, sense: entry.senses[0], plan: plan)
        #expect(content.answer.isEmpty)
        let values = ReviewCardPolicy.values(content, identity: entry.senses[0].id).reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value }
        #expect(values["Meaning"]?.contains(image.reference.filename) == true)
        #expect(values["Meaning"]?.contains("&lt;river&gt;") == true)
        #expect(!AnkiNoteTemplate.preview(fields: values, gap: false, back: false).contains(image.reference.filename))
        #expect(!AnkiNoteTemplate.preview(fields: values, gap: true, back: false).contains(image.reference.filename))
        #expect(AnkiNoteTemplate.preview(fields: values, gap: false, back: true).contains(image.reference.filename))
        var excluded = plan; excluded.includeSenseContent = false
        #expect(throws: (any Error).self) { try ReviewCardPolicy.content(entry: entry, sense: entry.senses[0], plan: excluded) }
    }

    @Test func formattingEscapesTextAndLegacyPlansRemainUnchanged() throws {
        let block = VocabularyContentBlock(content: .text(.init(text: "<script>&", style: .bullet, bold: true, italic: true)))
        let html = VocabularyContentPolicy.html([block])
        #expect(html.contains("&lt;script&gt;&amp;"))
        #expect(html.contains("<strong>") && html.contains("<em>") && html.contains("<li>"))
        #expect(!html.contains("<script>"))
        let legacy = try JSONDecoder().decode(ReviewPlan.self, from: JSONEncoder().encode(ReviewPlan()))
        #expect(legacy.includeSenseContent == nil)
    }

    @Test func validBackupRepairsCorruptedMediaAndHasPrivatePermissions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notebook.sqlite")
        let archive = VocabularyArchive(url: url)
        let original = try await archive.save(capture()).document.entries[0]
        let image = try await archive.prepareImage(VocabularyImageTestFixture.png())
        var edited = original
        edited.senses[0].content = [.init(content: .image(image.reference, caption: ""))]
        _ = try await archive.update(edited, basedOn: original, importedImages: [image.reference.filename: image.data])
        let backup = folder.appendingPathComponent("backup.lingrove")
        try await archive.backup(to: backup)
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let mediaURL = folder.appendingPathComponent("notebook.sqlite.media").appendingPathComponent(image.reference.filename)
        try Data("damaged".utf8).write(to: mediaURL)
        await #expect(throws: (any Error).self) { try await archive.image(image.reference) }
        _ = try await archive.restore(from: backup)
        #expect(try await VocabularyArchive(url: url).image(image.reference) == image.data)
    }

    @Test func invalidCountsAndOversizedReadsThrowInsteadOfAllocatingOrOverflowing() throws {
        let invalid = VocabularyImageReference(digest: String(repeating: "a", count: 64), width: 1, height: 1, byteCount: Int.max)
        #expect(throws: (any Error).self) {
            try VocabularyContentPolicy.validate([.init(content: .image(invalid, caption: "")),
                .init(content: .image(invalid, caption: ""))])
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 1, count: 100).write(to: file)
        #expect(throws: VocabularyError.oversizedArchive) { try VocabularyImageStorage.boundedRead(file, maximum: 10) }
        #expect(try VocabularyImageStorage.boundedRead(file, maximum: 100).count == 100)
    }

    @Test @MainActor func cancellingStalledImageProviderReleasesAwaitingTask() async throws {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { _ in
            Progress(totalUnitCount: 1)
        }
        let task = Task { try await VocabularyImageTransfer.load(provider, type: UTType.png.identifier) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// A tiny generated PNG makes image IO tests independent of developer files and external URLs.
nonisolated enum VocabularyImageTestFixture {
    static func png(width: Int = 80, height: Int = 40) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage()), output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
