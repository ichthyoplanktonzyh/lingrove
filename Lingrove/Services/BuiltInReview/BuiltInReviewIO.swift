import CryptoKit
import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// The app-owned review session owns this serial IO worker. Each operation opens and retires
/// a short connection to the repository's same physical database/media root. Only immutable
/// scopes and results cross the actor; the repository's non-Sendable engine never does.
actor BuiltInReviewIO {
    enum Command: Sendable {
        case enrollNotes([VocabularySelection], ReviewNoteType, LingroveNotebookSnapshot)
        case noteType(ReviewNoteType, ReviewNoteType?, LingroveNotebookSnapshot, Bool)
        case note(ReviewNoteEditorDraft)
        case save(BuiltInReviewDraft)
        case batch(BuiltInReviewBatchDraft)
        case status(LingroveNotebookReviewStatus, NotebookBuiltInReviewAction, UUID)
        case rate(BuiltInReviewCardContext, ReviewRating, Date, String)
        case undo(BuiltInReviewUndoAction)
        case retain(BuiltInReviewCardContext)
    }

    private let databaseURL: URL
    private let mediaDirectoryURL: URL

    init(databaseURL: URL, mediaDirectoryURL: URL) {
        self.databaseURL = databaseURL
        self.mediaDirectoryURL = mediaDirectoryURL
    }

    func load(scope: LingroveNotebookSnapshot, now: Date) throws -> NotebookBuiltInReviewSnapshot {
        try withEngine { try $0.loadBuiltInNotebookReview(scope: scope, now: now) }
    }

    func perform(_ command: Command) throws {
        try withEngine { engine in
            switch command {
            case let .enrollNotes(selections, type, scope):
                _ = try engine.enrollReviewNotes(selections: selections, type: type, scope: scope)
            case let .noteType(type, expected, scope, makeDefault):
                try engine.saveReviewNoteType(type, expected: expected, scope: scope, makeDefault: makeDefault)
            case let .note(draft):
                var value = draft.note; value.revision = draft.expected.revision + 1
                try engine.saveReviewNote(value, expected: draft.expected, scope: draft.scope)
            case let .save(draft):
                switch draft.purpose {
                case .enrollment:
                    _ = try engine.enrollBuiltInNotebookSense(draft.creationDraft(), input: draft.input,
                        media: draft.preparedMedia, action: draft.action)
                case .additionalExercise:
                    _ = try engine.addBuiltInNotebookExercise(draft.creationDraft(), input: draft.input,
                        media: draft.preparedMedia, action: draft.action)
                case let .editing(card, link):
                    if LingroveNotebookCardMaterial.resolvedSelection(source: link.source, snapshot: draft.snapshot) == nil {
                        try engine.saveRetainedBuiltInNotebookMaterial(link: link, card: card, input: draft.input,
                            materialPlan: draft.materialPlan, media: draft.preparedMedia, action: draft.action)
                    } else {
                        try engine.prepareNotebookExercise(link: link, card: card, snapshot: draft.snapshot,
                            exampleID: draft.exampleID, input: draft.input, materialPlan: draft.materialPlan,
                            media: draft.preparedMedia, action: draft.action)
                    }
                }
            case let .batch(batch):
                _ = try engine.enrollReviewNotes(selections: batch.drafts.map(\.selection),
                    type: batch.content.defaultNoteType, scope: batch.content.scope)
            case let .status(status, action, requestID):
                try engine.setBuiltInNotebookReviewStatus(status, action: action, requestID: requestID)
            case let .rate(context, rating, now, zone):
                _ = try engine.submitBuiltInNotebookRating(.init(cardId: context.card.cardId, rating: rating,
                    reviewedAtClient: formatIsoTimestamp(date: now), reviewedTimeZone: zone),
                    card: context.card, action: context.action)
            case let .undo(undo):
                try engine.undoBuiltInNotebookRating(undo.identity, action: undo.action)
            case let .retain(context):
                try engine.retainNotebookExercise(link: context.link, card: context.card,
                    snapshot: context.snapshot, action: context.action)
            }
        }
    }

    /// Rendering can read only a bounded local PNG referenced by this exact saved Card. An
    /// unfamiliar HTTPS image, a source_url or an arbitrary path is never fetched by opening a
    /// face. Metadata ownership, byte count and digest are rechecked before bytes leave IO.
    func savedImages(context: BuiltInReviewCardContext) throws -> [BuiltInReviewSavedImage] {
        try withEngine { engine in
            try engine.core.inReadTransaction {
                try engine.lingroveNotebookCardLinkStore.requireActiveScope(workspaceId: context.snapshot.workspaceId,
                    notebookId: context.snapshot.notebookId)
                guard try engine.lingroveNotebookStore.readSnapshot(workspaceId: context.snapshot.workspaceId) == context.snapshot,
                      try engine.cardStore.loadOptionalCardIncludingDeleted(workspaceId: context.snapshot.workspaceId,
                          cardId: context.card.cardId) == context.card, invalidFsrsStateReason(card: context.card) == nil
                else { throw VocabularyError.editConflict }
                let ids = managedMediaAssetIdsReferencedInMarkdown(text: context.card.frontText + "\n" + context.card.backText)
                var result: [BuiltInReviewSavedImage] = []
                // A recipe can combine the corpus's image allowance with card-only content.
                // Bound the combined read as well as each blob, without hiding valid later parts.
                var remainingBytes = Int64(VocabularyContentPolicy.maximumSenseImageBytes * 2)
                for id in ids.sorted().prefix(128) {
                    try Task.checkCancellation()
                    guard let asset = try engine.mediaAssetStore.loadOptionalMediaAssetIncludingDeleted(
                        workspaceId: context.snapshot.workspaceId, mediaAssetId: id), asset.deletedAt == nil,
                        asset.mimeType == "image/png", asset.sizeBytes > 0, asset.sizeBytes <= 16_777_216,
                        asset.sizeBytes <= remainingBytes else { continue }
                    if let saved = try LingroveNotebookReviewMediaStore(core: engine.core).media(assetID: id,
                        workspaceID: context.snapshot.workspaceId) {
                        result.append(.init(id: id, data: saved.data))
                        remainingBytes -= Int64(saved.data.count)
                        continue
                    }
                    let digest = try normalizedMediaSha256(sha256: asset.sha256)
                    let url = mediaDirectoryURL.appendingPathComponent(try mediaBlobCacheRelativePath(sha256: digest))
                    guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                    defer { try? handle.close() }
                    // Bound the actual read as well as the metadata. A corrupted local file
                    // must not make opening a question allocate its unbounded on-disk size.
                    guard let bytes = try? handle.read(upToCount: Int(asset.sizeBytes) + 1),
                          Int64(bytes.count) == asset.sizeBytes,
                          SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else { continue }
                    result.append(.init(id: id, data: bytes))
                    remainingBytes -= Int64(bytes.count)
                }
                return result
            }
        }
    }

    func savedAudio(context: BuiltInReviewCardContext) throws -> [BuiltInReviewSavedAudio] {
        try withEngine { engine in
            try engine.core.inReadTransaction {
                try engine.lingroveNotebookCardLinkStore.requireActiveScope(workspaceId: context.snapshot.workspaceId,
                    notebookId: context.snapshot.notebookId)
                guard try engine.lingroveNotebookStore.readSnapshot(workspaceId: context.snapshot.workspaceId) == context.snapshot,
                      try engine.cardStore.loadOptionalCardIncludingDeleted(workspaceId: context.snapshot.workspaceId,
                          cardId: context.card.cardId) == context.card else { throw VocabularyError.editConflict }
                let recordings = (context.link.materialPlan?.audio ?? [:]).sorted { $0.key.rawValue < $1.key.rawValue }
                return try recordings.compactMap { kind, audio in
                    let id = LingroveNotebookCardMaterial.mediaAssetID(reference: audio.reference,
                        workspaceID: context.snapshot.workspaceId)
                    guard let media = try LingroveNotebookReviewMediaStore(core: engine.core).media(assetID: id,
                        workspaceID: context.snapshot.workspaceId) else { return nil }
                    return .init(id: id, kind: kind, data: media.data,
                        fileExtension: audio.reference.mimeType == "audio/mpeg" ? "mp3" : "wav")
                }
            }
        }
    }

    /// A sheet may reopen card-only resources without importing them into the corpus. The same
    /// saved scope fences this read; bytes remain in the sheet until an explicit writer uses them.
    func materialMedia(draft: BuiltInReviewDraft) throws -> [ReviewMaterialPreparedMedia] {
        try withEngine { engine in
            try engine.core.inReadTransaction {
                try engine.lingroveNotebookCardLinkStore.requireActiveScope(workspaceId: draft.snapshot.workspaceId,
                    notebookId: draft.snapshot.notebookId)
                guard try engine.lingroveNotebookStore.readSnapshot(workspaceId: draft.snapshot.workspaceId) == draft.snapshot else {
                    throw VocabularyError.editConflict
                }
                let images = VocabularyContentPolicy.images(draft.materialPlan.layout.customContent)
                    .map(ReviewMaterialMediaReference.init(image:))
                let references = Set(images + draft.materialPlan.audio.values.map(\.reference))
                return try references.compactMap { reference in
                    let id = LingroveNotebookCardMaterial.mediaAssetID(reference: reference, workspaceID: draft.snapshot.workspaceId)
                    return try LingroveNotebookReviewMediaStore(core: engine.core).media(assetID: id,
                        workspaceID: draft.snapshot.workspaceId)
                }
            }
        }
    }

    private func withEngine<T>(_ operation: (LingroveNotebookEngine) throws -> T) throws -> T {
        try Task.checkCancellation()
        let engine = try LingroveNotebookEngine(databaseURL: databaseURL, mediaDirectoryURL: mediaDirectoryURL)
        defer { try? engine.close() }
        return try operation(engine)
    }
}
