import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import LingroveNotebook
import LingroveNotebookEngine
import UniformTypeIdentifiers

/// Synthetic PNGs give each owner a distinct digest without loading user files or images.
func candidateImage(_ index: Int) throws -> VocabularyPreparedImage {
    let pixels: [UInt8] = [UInt8(index % 256), UInt8(index / 256), 80, 255, 30, 140, 210, 255]
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let data = NSMutableData()
    let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    precondition(CGImageDestinationFinalize(output))
    let bytes = data as Data
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return .init(reference: .init(digest: digest, width: 2, height: 1, byteCount: bytes.count), data: bytes)
}

func candidateSeedImages(entries: inout [VocabularyEntry]) throws -> [String: Data] {
    guard ProcessInfo.processInfo.environment["LINGROVE_PAIRED_CANDIDATES"] == "1" else { return [:] }
    var images: [String: Data] = [:]
    for index in 0..<512 {
        let image = try candidateImage(index)
        entries[1_000 + index].senses[0].content = [.init(content: .image(image.reference, caption: "Synthetic image"))]
        images[image.reference.filename] = image.data
        if index == 0 { entries[42].senses[0].content = [.init(content: .image(image.reference, caption: "Shared owner"))] }
    }
    return images
}

/// Every command receives a newly opened connection and its own closed seed copy. Draft
/// construction, installation/certification and verification are outside its timed window.
/// The same public fallback sequence is compiled against both engine revisions.
func measureCandidate(_ name: String, engine: LingroveNotebookEngine, count: Int) throws {
    let version = try engine.currentNotebookVersion()!
    if name == "tag_filter" {
        let start = ContinuousClock.now
        let page = try engine.browseNotebook(.init(language: .english, tag: "group-2"))
        let duration = start.duration(to: .now).components
        precondition(page.total == count / 20)
        try emitCandidate(milliseconds: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15, mode: "page")
        return
    }
    let owner = name.hasPrefix("reviewed_") ? 40 : name == "sense_create" ? 44 : name == "image_remove_last" ? 1_001 : 42
    let original = try engine.notebookEntryDetail(entryID: identifier(1_000_000 + owner)).entry!
    let entry = try candidateEntry(name, original: original)
    let links = try engine.loadLingroveNotebookCardLinks(workspaceId: version.workspaceId)
        .filter { $0.source.entryId == original.id }
    let priorCards = try links.map { try engine.loadActiveCard(workspaceId: version.workspaceId, cardId: $0.cardId) }
    let start = ContinuousClock.now
    let mode: String
    if try engine.trySaveNotebookEntry(entry, basedOn: version) != nil { mode = "local" } else {
        let full = try engine.loadLingroveNotebook(workspaceId: version.workspaceId)
        _ = try engine.saveNotebookEntry(entry, basedOn: full)
        mode = "full"
    }
    let duration = start.duration(to: .now).components
    let actual = try engine.notebookEntryDetail(entryID: entry.id).entry!
    precondition(actual.senses.count == entry.senses.count && actual.examples.count == entry.examples.count)
    let eventCount = try engine.loadReviewEventCount()
    precondition(eventCount == 1_000)
    for before in priorCards {
        let after = try engine.loadActiveCard(workspaceId: version.workspaceId, cardId: before.cardId)
        precondition(after.reps == before.reps && after.dueAt == before.dueAt && after.fsrsCardState == before.fsrsCardState)
        precondition(after.fsrsStability == before.fsrsStability && after.fsrsDifficulty == before.fsrsDifficulty)
    }
    if name == "shared_source" { precondition(actual.examples[0].sourceID == original.examples[0].sourceID) }
    if name == "image_remove_shared" {
        let other = try engine.notebookEntryDetail(entryID: identifier(1_001_000))
        let image = try candidateImage(0)
        let bytes = try engine.notebookEntryImage(image.reference, detail: other)
        precondition(bytes == image.data)
    }
    try emitCandidate(milliseconds: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15, mode: mode)
}

private func candidateEntry(_ name: String, original: VocabularyEntry) throws -> VocabularyEntry {
    var entry = original
    switch name {
    case "reviewed_append":
        var example = original.senses[0].examples[0].copiedWithNewID()
        example.text = "An additional reviewed source context."
        entry.senses[0].examples.append(example)
    case "reviewed_note": entry.senses[0].note = "A corrected note on a reviewed source"
    case "cited_example_edit": entry.senses[0].examples[0].meaning = "A corrected contextual definition"
    case "shared_source", "plain_capture_images":
        var example = original.senses[0].examples[0].copiedWithNewID()
        if name == "plain_capture_images" { example.sourceID = UUID(); example.text = "An unrelated new capture." }
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        entry = .init(id: UUID(), expression: "new-candidate", dictionaryForm: "new-candidate", language: .english,
            kind: .word, senses: [.init(id: UUID(), meaning: "New sense", examples: [example],
                createdAt: date, updatedAt: date)], createdAt: date, updatedAt: date)
    case "image_add":
        entry.senses[0].content = (entry.senses[0].content ?? []) + [
            .init(content: .image(try candidateImage(512).reference, caption: "Prepared owned image"))]
    case "image_remove_shared", "image_remove_last": entry.senses[0].content = []
    case "sense_create":
        entry.senses.append(.init(id: UUID(), meaning: "Additional sense", createdAt: Date(), updatedAt: Date()))
    default: fatalError("Unknown candidate \(name)")
    }
    return entry
}

private func emitCandidate(milliseconds: Double, mode: String) throws {
    let output: [String: Any] = ["milliseconds": milliseconds, "mode": mode]
    let bytes = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    guard let text = String(data: bytes, encoding: .utf8) else { fatalError("Invalid fixture output") }
    print(text)
}
