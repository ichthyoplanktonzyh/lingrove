import Foundation
import LingroveNotebook

/// Version-three review metadata travels with the held Card lane. The server must explicitly
/// acknowledge the exact sent digest; a version-two response cannot release note-based Cards.
public struct ReviewNoteSyncState: Codable, Equatable, Sendable {
    public let types: [ReviewNoteType]
    public let notes: [ReviewNote]
    public let memberships: [ReviewNoteStore.Membership]
    public let defaultRevision: UInt64
    public let defaultTypeID: UUID
    public init(types: [ReviewNoteType], notes: [ReviewNote], memberships: [ReviewNoteStore.Membership], defaultTypeID: UUID, defaultRevision: UInt64 = 1) {
        self.types = types; self.notes = notes; self.memberships = memberships; self.defaultTypeID = defaultTypeID; self.defaultRevision = defaultRevision
    }
    public func digest() throws -> String { try LingroveNotebookCardMaterial.fingerprint(self) }
}
