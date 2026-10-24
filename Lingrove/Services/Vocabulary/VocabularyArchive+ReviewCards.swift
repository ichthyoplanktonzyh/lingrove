import Foundation

/// Card transactions share the notebook actor and media commit point. Saving one card compares
/// only that card, so another card can be edited without losing its receipt or imported images.
extension VocabularyArchive {
    func validateCards(_ cards: [VocabularyReview], ids: inout Set<UUID>) throws {
        guard cards.count <= 64 else { throw VocabularyError.invalidArchive }
        for card in cards {
            guard ids.insert(card.plan.id).inserted, let layout = card.plan.layout else { throw VocabularyError.invalidArchive }
            try ReviewLayoutPolicy.validate(layout)
            try validateReview(card)
        }
    }

    func removeReview(entryID: UUID, senseID: UUID, cardID: UUID, expected: VocabularyReview) throws -> VocabularySnapshot {
        var document = try load().document
        guard let entry = document.entries.firstIndex(where: { $0.id == entryID }),
              let sense = document.entries[entry].senses.firstIndex(where: { $0.id == senseID }),
              document.entries[entry].senses[sense].reviewValue(cardID) == expected else { throw VocabularyError.editConflict }
        document.entries[entry].senses[sense].reviewCards?.removeAll { $0.plan.id == cardID }
        return try commit(document)
    }

    func saveTemplate(_ template: ReviewLayoutTemplate, importedImages: [String: Data] = [:]) throws -> VocabularySnapshot {
        try Task.checkCancellation()
        var document = try load().document
        var templates = document.reviewTemplates ?? []
        if let index = templates.firstIndex(where: { $0.id == template.id }) {
            templates[index] = template
        } else { templates.append(template) }
        try validateTemplates(templates)
        document.reviewTemplates = templates
        return try commitWithImages(document, supplied: importedImages)
    }

    func removeTemplate(_ id: UUID) throws -> VocabularySnapshot {
        var document = try load().document
        document.reviewTemplates?.removeAll { $0.id == id }
        return try commit(document)
    }

    func validateTemplates(_ templates: [ReviewLayoutTemplate]) throws {
        guard templates.count <= 64, Set(templates.map(\.id)).count == templates.count else { throw VocabularyError.invalidArchive }
        for template in templates {
            guard !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  template.name.utf8.count <= 1024 else { throw VocabularyError.invalidArchive }
            try ReviewLayoutPolicy.validate(template.layout)
        }
    }
}
