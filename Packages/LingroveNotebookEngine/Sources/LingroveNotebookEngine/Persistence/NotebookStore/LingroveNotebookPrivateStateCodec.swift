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
        return .init(notebookID: notebookID, explanations: try archive.explanations.map { try $0.value() })
    }

    /// This private envelope versions only local persistence, independently of
    /// the public protocol and of the main notebook document schema.
    private struct Archive: Codable {
        let version: Int
        let notebookID: UUID
        let explanations: [Explanation]
        init(_ state: VocabularyWirePrivateState) {
            version = 1; notebookID = state.notebookID
            explanations = state.explanations.map(Explanation.init)
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
        static func validSignature(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        func value() throws -> VocabularyWirePrivateState.Explanation {
            guard [.senseExplanation, .interpretationExplanation].contains(ownerKind), Self.validSignature(inputSignature) else { throw VocabularyError.invalidArchive }
            return .init(ownerKind: ownerKind, ownerID: ownerID, explanationID: explanationID,
                         inputSignature: inputSignature, occurrenceIdentity: occurrenceIdentity)
        }
    }
}
