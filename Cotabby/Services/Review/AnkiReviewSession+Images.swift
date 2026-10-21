import Foundation

/// Image transport reuses the same explicit Anki send operation and profile/content guards as
/// audio. Hash filenames are stable across retries. Uploading precedes note writes, so no note
/// can acknowledge a local image that was never sent; cancellation never deletes remote media.
extension AnkiReviewSession {
    /// Older official templates exposed Meaning on the gap front. Check the live template at
    /// send time, not only cached sheet metadata, before placing image answers in that field.
    func validateImageTemplate(_ content: ReviewCardContent, connection: AnkiConnection) async throws {
        guard model == AnkiReviewPolicy.presetName, plan.gap, !content.senseContent.isEmpty else { return }
        let models = try controller.strings(await controller.call("modelNames", [:], connection))
        try validateCurrent(content, connection: connection)
        guard models.contains(model) else { return }
        let templates = try await controller.call("modelTemplates", ["modelName": .string(model)], connection)
        try validateCurrent(content, connection: connection)
        guard templates.object?["Gap"]?.object?["Front"]?.string == AnkiNoteTemplate.gapFront else {
            throw AnkiReviewError.message(String(
                localized: "Update the Lingrove template before adding explanation content to gap cards.", table: "Vocabulary"))
        }
    }

    func uploadImages(_ content: ReviewCardContent, connection: AnkiConnection, profile: String) async throws {
        for image in Set(VocabularyContentPolicy.images(content.senseContent)) {
            try Task.checkCancellation()
            guard let data = await controller.store.image(image) else {
                throw AnkiReviewError.message(String(localized: "An explanation image is missing. Add it again before sending.",
                    table: "Vocabulary"))
            }
            try validateCurrent(content, connection: connection)
            guard try await controller.profile(connection) == profile else { throw VocabularyError.editConflict }
            try validateCurrent(content, connection: connection)
            let stored = try await controller.call("storeMediaFile", ["filename": .string(image.filename),
                "data": .string(data.base64EncodedString())], connection)
            guard stored.string == image.filename, try await controller.profile(connection) == profile else { throw controller.invalid() }
            try validateCurrent(content, connection: connection)
        }
    }
}
