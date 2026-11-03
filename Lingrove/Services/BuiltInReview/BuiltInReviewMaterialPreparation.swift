import Foundation
import LingroveNotebook

/// The sheet borrows speech through this adapter and receives a new value draft. Recordings
/// stay in memory until the shared writer commits recipe, bytes and Card together. Cancellation
/// can therefore discard generation without leaving media or enrollment rows behind.
@MainActor
enum BuiltInReviewMaterialPreparation {
    static func text(_ kind: ReviewAudioKind, draft: BuiltInReviewDraft) throws -> String {
        guard let source = BuiltInReviewSource.value(draft.selection, in: draft.snapshot) else { throw VocabularyError.invalidContent }
        let value = kind == .expression ? source.entry.expression : source.sense.examples.first { $0.id == draft.exampleID }?.text
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VocabularyError.invalidContent }
        return value
    }

    static func needsAudio(_ kind: ReviewAudioKind, draft: BuiltInReviewDraft) -> Bool {
        guard let text = try? text(kind, draft: draft) else { return true }
        return draft.materialPlan.audio[kind]?.textHash != ReviewMaterialAudio.textHash(text)
    }

    static func prepare(_ kind: ReviewAudioKind, draft: BuiltInReviewDraft, audio: ReviewAudioPreparation,
                        audition: Bool) async throws -> BuiltInReviewDraft {
        guard let source = BuiltInReviewSource.value(draft.selection, in: draft.snapshot), let speech = audio.speech else {
            throw SpeechError.incompleteConfiguration
        }
        let text = try text(kind, draft: draft)
        let context = source.sense.examples.first { $0.id == draft.exampleID }?.text
        let request = try speech.exportRequest(text: text, language: source.entry.language, context: context)
        if let saved = draft.materialPlan.audio[kind], saved.textHash == ReviewMaterialAudio.textHash(text),
           saved.fingerprint == request.fingerprint,
           let media = draft.preparedMedia.first(where: { $0.reference == saved.reference }) {
            if audition {
                try speech.audition(.init(data: media.data, fileExtension: saved.reference.mimeType == "audio/mpeg" ? "mp3" : "wav"),
                    ownerID: audio.ownerID, language: request.language)
            }
            return draft
        }
        let prepared = try await audio.prepare(kind, request: request)
        try Task.checkCancellation()
        let reference = ReviewMaterialMediaReference(digest: ReviewMaterialMediaReference.digest(prepared.audio.data),
            mimeType: prepared.audio.fileExtension == "mp3" ? "audio/mpeg" : "audio/wav", byteCount: prepared.audio.data.count)
        var result = draft
        var plan = result.materialPlan
        plan.audio[kind] = .init(reference: reference, textHash: ReviewMaterialAudio.textHash(text), fingerprint: request.fingerprint)
        result.preparedMedia.removeAll { $0.reference == reference }
        result.preparedMedia.append(.init(reference: reference, data: prepared.audio.data))
        result.chooseMaterial(plan)
        if audition { try speech.audition(prepared.audio, ownerID: audio.ownerID, language: request.language) }
        return result
    }

    static func stageImages(_ draft: BuiltInReviewDraft) -> BuiltInReviewDraft {
        var result = draft
        let images = VocabularyContentPolicy.images(draft.materialPlan.layout.customContent)
        let references = Set(images.map(ReviewMaterialMediaReference.init(image:)) + draft.materialPlan.audio.values.map(\.reference))
        result.preparedMedia = result.preparedMedia.filter { references.contains($0.reference) }
        for image in images {
            guard let bytes = draft.importedImages[image.filename] else { continue }
            let reference = ReviewMaterialMediaReference(image: image)
            result.preparedMedia.removeAll { $0.reference == reference }
            result.preparedMedia.append(.init(reference: reference, data: bytes))
        }
        return result
    }
}
