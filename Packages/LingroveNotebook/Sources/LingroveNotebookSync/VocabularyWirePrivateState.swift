import Foundation
import LingroveNotebook

/// Private values are scoped to the server book selected by the host. They have
/// no Codable conformance and no place in the remote schema. The local database
/// adapter will own durable storage and account/book adoption, not this mapper.
public nonisolated struct VocabularyWirePrivateState: Equatable, Sendable {
    public let notebookID: UUID
    public let reviews: [Review]
    public let explanations: [Explanation]

    public init(notebookID: UUID, reviews: [Review] = [], explanations: [Explanation] = []) {
        self.notebookID = notebookID; self.reviews = reviews; self.explanations = explanations
    }

    public enum Role: Hashable, Sendable { case legacy, card(UUID) }

    /// Binding identity follows an original sense through mergedFrom; its own
    /// originSenseID is never rewritten to the survivor. Audio remains plan-owned.
    public struct Review: Equatable, Sendable {
        public let senseID: UUID
        public let role: Role
        public var bindings: [AnkiNoteBinding]
        public var activeBindingID: UUID?
        public var audio: [Audio]

        public init(senseID: UUID, role: Role, bindings: [AnkiNoteBinding], activeBindingID: UUID?, audio: [Audio]) {
            self.senseID = senseID; self.role = role; self.bindings = bindings
            self.activeBindingID = activeBindingID; self.audio = audio
        }
    }

    public struct Audio: Equatable, Sendable {
        public let planID: UUID
        /// Position only disambiguates legal repeated legacy plan IDs on an
        /// unchanged round trip; matching a moved plan also checks its signature.
        public let preservedIndex: Int?
        public let materialSignature: String
        public let receipts: [ReviewAudioKind: ReviewAudioReceipt]

        public init(planID: UUID, preservedIndex: Int?, materialSignature: String, receipts: [ReviewAudioKind: ReviewAudioReceipt]) {
            self.planID = planID; self.preservedIndex = preservedIndex
            self.materialSignature = materialSignature; self.receipts = receipts
        }
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
