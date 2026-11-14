import Foundation
import LingroveNotebook

/// Private values are scoped to the server book selected by the host. They have
/// no Codable conformance and no place in the remote schema. The local database
/// adapter will own durable storage and account/book adoption, not this mapper.
public nonisolated struct VocabularyWirePrivateState: Equatable, Sendable {
    public let notebookID: UUID
    public let explanations: [Explanation]

    public init(notebookID: UUID, explanations: [Explanation] = []) {
        self.notebookID = notebookID; self.explanations = explanations
    }

    public struct Explanation: Equatable, Sendable {
        public let ownerKind: VocabularyWireEntityKind
        public let ownerID: UUID
        public let explanationID: UUID
        public let inputSignature: String
        public let occurrenceIdentity: String?

        public init(ownerKind: VocabularyWireEntityKind, ownerID: UUID, explanationID: UUID, inputSignature: String, occurrenceIdentity: String?) {
            self.ownerKind = ownerKind; self.ownerID = ownerID; self.explanationID = explanationID
            self.inputSignature = inputSignature; self.occurrenceIdentity = occurrenceIdentity
        }
    }
}
