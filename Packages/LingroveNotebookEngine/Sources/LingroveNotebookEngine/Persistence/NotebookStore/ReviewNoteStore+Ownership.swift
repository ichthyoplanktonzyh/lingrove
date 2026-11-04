import Foundation
import LingroveNotebook

extension ReviewNoteStore {
    /// Explicit account handoff copies note ownership alongside the already-forked Cards. A
    /// colliding type is copied under a deterministic new identity instead of overwriting the
    /// account's definition. Neither the source nor either side's sync receipts are retargeted.
    func copyOwnership(source: String, target: String, cardIDs: [String: String]) throws {
        let notebooks = LingroveNotebookStore(core: core)
        let sourceScope = try notebooks.readSnapshot(workspaceId: source)
        let targetScope = try notebooks.readSnapshot(workspaceId: target)
        let targetTypes = try types(workspace: target)
        var typeIDs: [UUID: UUID] = [:]
        for original in try types(workspace: source) {
            var copied = original
            if let existing = targetTypes.first(where: { $0.id == original.id }), existing != original {
                copied.id = LingroveNotebookCardMaterial.stableID("note-type-handoff|" + source,
                    workspace: target, sense: original.id)
                copied.revision = 1
            }
            typeIDs[original.id] = copied.id
            try put(copied, workspace: target)
        }
        let members = try memberships(workspace: source)
        for original in try notes(scope: sourceScope) {
            let copiedMembers = members.filter { $0.noteID == original.id && cardIDs[$0.cardID] != nil }
            guard !copiedMembers.isEmpty, let typeID = typeIDs[original.noteTypeID] else { continue }
            var copied = original
            copied.id = LingroveNotebookCardMaterial.stableID("note-handoff|" + source,
                workspace: target, sense: original.id)
            copied.noteTypeID = typeID
            try put(copied, scope: targetScope)
            for member in copiedMembers {
                guard let cardID = cardIDs[member.cardID] else { continue }
                try attach(.init(noteID: copied.id, templateID: member.templateID, cardID: cardID), workspace: target)
            }
        }
    }
}
