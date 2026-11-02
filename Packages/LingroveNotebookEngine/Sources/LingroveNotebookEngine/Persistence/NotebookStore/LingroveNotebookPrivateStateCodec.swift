import Foundation
import LingroveNotebook
import LingroveNotebookSync

/// SQLite-only archive for private remainders returned by materialization. The
/// public sync values intentionally stay non-Codable, so neither a network
/// encoder nor a projected entity can accidentally carry Anki/audio state.
/// The apply writer owns these bytes in the same transaction as its document.
public enum LingroveNotebookPrivateStateCodec {
    public static func encode(_ state: VocabularyWirePrivateState) throws -> String {
        let data = try JSONEncoder().encode(Archive(state))
        guard let text = String(data: data, encoding: .utf8) else { throw VocabularyError.invalidArchive }
        return text
    }
    public static func decode(_ text: String, notebookID: UUID) throws -> VocabularyWirePrivateState {
        let archive = try JSONDecoder().decode(Archive.self, from: Data(text.utf8))
        guard archive.version == 1, archive.notebookID == notebookID else { throw VocabularyError.invalidArchive }
        return .init(notebookID: notebookID, reviews: try archive.reviews.map { try $0.value() },
                     explanations: try archive.explanations.map { try $0.value() })
    }

    /// This private envelope versions only local persistence, independently of
    /// the public protocol and of the main notebook document schema.
    private struct Archive: Codable {
        let version: Int
        let notebookID: UUID
        let reviews: [Review]
        let explanations: [Explanation]
        init(_ state: VocabularyWirePrivateState) {
            version = 1; notebookID = state.notebookID
            reviews = state.reviews.map(Review.init); explanations = state.explanations.map(Explanation.init)
        }
    }
    private struct Review: Codable {
        let senseID: UUID
        let role: String
        let cardID: UUID?
        let bindings: [AnkiNoteBinding]
        let activeBindingID: UUID?
        let audio: [Audio]
        init(_ value: VocabularyWirePrivateState.Review) {
            senseID = value.senseID; bindings = value.bindings; activeBindingID = value.activeBindingID
            audio = value.audio.map(Audio.init)
            switch value.role {
            case .legacy: role = "legacy"; cardID = nil
            case let .card(id): role = "card"; cardID = id
            }
        }
        func value() throws -> VocabularyWirePrivateState.Review {
            let restored: VocabularyWirePrivateState.Role
            if role == "legacy", cardID == nil { restored = .legacy }
            else if role == "card", let cardID { restored = .card(cardID) }
            else { throw VocabularyError.invalidArchive }
            return .init(senseID: senseID, role: restored, bindings: bindings,
                         activeBindingID: activeBindingID, audio: try audio.map { try $0.value() })
        }
    }
    private struct Audio: Codable {
        let planID: UUID
        let preservedIndex: Int?
        let materialSignature: String
        let receipts: [ReviewAudioKind: ReviewAudioReceipt]
        init(_ value: VocabularyWirePrivateState.Audio) {
            planID = value.planID; preservedIndex = value.preservedIndex
            materialSignature = value.materialSignature; receipts = value.receipts
        }
        func value() throws -> VocabularyWirePrivateState.Audio {
            guard Self.validSignature(materialSignature), preservedIndex.map({ $0 >= 0 }) ?? true else { throw VocabularyError.invalidArchive }
            return .init(planID: planID, preservedIndex: preservedIndex, materialSignature: materialSignature, receipts: receipts)
        }
        static func validSignature(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
    private struct Explanation: Codable {
        let ownerKind: VocabularyWireEntityKind
        let ownerID: UUID
        let explanationID: UUID
        let inputSignature: String
        let occurrenceIdentity: String?
        init(_ value: VocabularyWirePrivateState.Explanation) {
            ownerKind = value.ownerKind; ownerID = value.ownerID; explanationID = value.explanationID
            inputSignature = value.inputSignature; occurrenceIdentity = value.occurrenceIdentity
        }
        func value() throws -> VocabularyWirePrivateState.Explanation {
            guard [.senseExplanation, .interpretationExplanation].contains(ownerKind), Audio.validSignature(inputSignature) else { throw VocabularyError.invalidArchive }
            return .init(ownerKind: ownerKind, ownerID: ownerID, explanationID: explanationID,
                         inputSignature: inputSignature, occurrenceIdentity: occurrenceIdentity)
        }
    }
}
