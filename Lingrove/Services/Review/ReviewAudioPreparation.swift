import Combine
import Foundation

/// One preparation sheet/session owns these short-lived recordings and borrows the app's speech
/// controller. Bytes are released on close. Only successful Anki filenames enter the saved plan.
@MainActor
final class ReviewAudioPreparation: ObservableObject {
    let ownerID = UUID()
    let speech: (any SpeechExporting)?
    @Published private(set) var prepared: [ReviewAudioKind: ReviewPreparedAudio] = [:]
    @Published private(set) var generating: ReviewAudioKind?
    init(speech: (any SpeechExporting)?) { self.speech = speech }

    func request(_ kind: ReviewAudioKind, entry: VocabularyEntry, content: ReviewCardContent) throws -> SpeechExportRequest {
        guard let speech else { throw SpeechError.incompleteConfiguration }
        return try speech.exportRequest(text: kind == .expression ? content.expression : content.sentence,
            language: entry.language, context: content.sentence.isEmpty ? nil : content.sentence)
    }
    func prepare(_ kind: ReviewAudioKind, request: SpeechExportRequest, force: Bool = false) async throws -> ReviewPreparedAudio {
        if !force, let current = prepared[kind], current.fingerprint == request.fingerprint { return current }
        guard generating == nil else { throw SpeechError.operationInProgress }
        speech?.stop(ownerID: ownerID)
        generating = kind
        defer { generating = nil }
        guard let speech else { throw SpeechError.incompleteConfiguration }
        let audio = try await speech.exportAudio(request)
        try Task.checkCancellation()
        let result = ReviewPreparedAudio(fingerprint: request.fingerprint, audio: audio)
        prepared[kind] = result
        return result
    }
    func audition(_ kind: ReviewAudioKind, request: SpeechExportRequest) async throws {
        let result = try await prepare(kind, request: request)
        try speech?.audition(result.audio, ownerID: ownerID, language: request.language)
    }
    func discard() { stopPreview(); prepared = [:] }
    func stopPreview() { speech?.stop(ownerID: ownerID) }
}
