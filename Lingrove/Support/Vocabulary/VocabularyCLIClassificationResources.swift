import Foundation

/// Classification uses the existing revisioned resource protocol. Built-in definitions are
/// read-only; agents edit local overlays or custom categories through the same closed contract.
/// The generic resource adapter supplies patch decoding, so this module only owns domain rules.
nonisolated enum VocabularyCLIClassificationResources {
    static func validatePut(_ input: CLIResourcePut, id: UUID, in index: VocabularyClassificationIndex) throws {
        switch input.resource {
        case "frameworks": throw CLIError.invalid("Frameworks are read-only catalog receipts.")
        case "categories":
            guard index.categories.first(where: { $0.id == id })?.frameworkID == nil else {
                throw CLIError.invalid("Built-in categories are read-only. Write categoryOverrides instead.")
            }
            guard case let .object(fields) = input.value,
                  fields["frameworkID"] == nil || fields["frameworkID"] == .null,
                  fields["key"] == nil || fields["key"] == .null,
                  fields["isRetired"] == nil || fields["isRetired"] == .bool(false) else {
                throw CLIError.invalid("Custom categories cannot claim catalog ownership.")
            }
        case "categoryParents":
            guard index.parents.first(where: { $0.id == id }).map({ edge in
                index.categories.first { $0.id == edge.categoryID }?.frameworkID == nil
            }) ?? true else { throw CLIError.invalid("Built-in category parents are read-only.") }
            guard case let .object(fields) = input.value else { throw CLIError.invalid("Expected a parent edge.") }
            let childID: UUID?
            if case let .string(text) = fields["categoryID"] { childID = UUID(uuidString: text) } else {
                childID = index.parents.first { $0.id == id }?.categoryID
            }
            guard let childID, index.categories.contains(where: { $0.id == childID && $0.frameworkID == nil }) else {
                throw CLIError.invalid("Only custom categories accept parent edits.")
            }
        default: break
        }
    }

    static func delete(_ input: CLIResourceDelete, from index: inout VocabularyClassificationIndex) throws {
        switch input.resource {
        case "frameworks": throw CLIError.invalid("Frameworks are read-only catalog receipts.")
        case "categories": try VocabularyClassificationPolicy.removeCategory(input.id, from: &index)
        case "categoryParents":
            guard let edge = index.parents.first(where: { $0.id == input.id }),
                  index.categories.contains(where: { $0.id == edge.categoryID && $0.frameworkID == nil }) else {
                throw CLIError.invalid("Built-in category parents are read-only.")
            }
            index.parents.removeAll { $0.id == input.id }
        case "categoryMemberships": index.memberships.removeAll { $0.id == input.id }
        case "categoryOverrides": index.overrides.removeAll { $0.id == input.id }
        default: break
        }
    }
}
