import Foundation

/// Capture and explicit append/edit commands share evidence ownership and translation rules.
/// This transaction-scoped module changes a detached document only; persistence supplies the
/// revision fence and deterministic IDs. Text equality never establishes source identity.
public nonisolated enum NotebookExampleWriting {
    public static func append(_ input: NotebookCaptureExample, entry: VocabularyEntry, senseID: UUID,
                              in document: inout VocabularyDocument, id: UUID, occurrenceID: UUID, now: Date) throws -> UUID {
        var input = input
        if let sourceID = input.sourceID {
            guard let source = document.sources.first(where: { $0.id == sourceID }) else {
                throw NotebookToolError(code: .notFound, message: "Referenced example source does not exist.")
            }
            if input.sourceKind == nil { input.sourceKind = source.kind.rawValue }
        }
        let value = try NotebookCaptureFields.example(input, expression: entry.expression, id: id, now: now)
        let citation = try NotebookCaptureFields.text(input.source ?? "", limit: 4_096)
        if let source = document.sources.first(where: { $0.id == value.sourceID }) {
            guard source.text.utf8.elementsEqual(value.text.utf8), source.kind == value.sourceKind else {
                throw NotebookToolError(code: .conflict, message: "Source identity is immutable. Omit sourceID for a new capture.")
            }
        } else {
            document.sources.append(.init(id: value.sourceID, text: value.text, kind: value.sourceKind,
                appBundleIdentifier: nil, encounteredAt: now))
        }
        let occurrence = document.occurrences.first { $0.sourceID == value.sourceID && $0.ranges == value.ranges }
        let resolvedID = occurrence?.id ?? occurrenceID
        if let index = document.interpretations.firstIndex(where: { $0.occurrenceID == resolvedID && $0.status == .accepted }) {
            guard document.interpretations[index].senseID == senseID else {
                throw NotebookToolError(code: .conflict, message: "This source occurrence belongs to another sense. Use an explicit edit or merge.")
            }
            guard citation.isEmpty || document.interpretations[index].provenance.source == citation else {
                throw NotebookToolError(code: .conflict, message: "Source citation differs. Edit the existing example explicitly.")
            }
            guard input.completeness == nil || value.completeness == document.interpretations[index].completeness else {
                throw NotebookToolError(code: .conflict, message: "Context completeness differs. Edit the existing example explicitly.")
            }
            addTranslation(value.translation, language: value.translationLanguage, to: &document.interpretations[index])
            return document.interpretations[index].id
        }
        if occurrence == nil { document.occurrences.append(.init(id: resolvedID, sourceID: value.sourceID, ranges: value.ranges)) }
        document.interpretations.append(.init(id: id, occurrenceID: resolvedID, senseID: senseID, status: .accepted,
            translation: value.translation, translationLanguage: value.translationLanguage, completeness: value.completeness,
            provenance: .init(origin: .model, status: .confirmed, source: citation), createdAt: now))
        return id
    }

    public static func edit(_ edit: NotebookExampleEdit, entry: VocabularyEntry, senseID: UUID,
                            in document: inout VocabularyDocument, sourceID: UUID, occurrenceID: UUID, now: Date) throws {
        guard let index = document.interpretations.firstIndex(where: { $0.id == edit.id && $0.status == .accepted && $0.senseID == senseID }),
              let occurrence = document.occurrences.first(where: { $0.id == document.interpretations[index].occurrenceID }),
              let source = document.sources.first(where: { $0.id == occurrence.sourceID }) else {
            throw NotebookToolError(code: .notFound, message: "Example does not belong to this sense.")
        }
        guard edit.text != nil || edit.translation != nil || edit.translationLanguage != nil || edit.completeness != nil ||
                edit.sourceKind != nil || edit.source != nil || edit.ranges != nil else {
            throw NotebookToolError.invalid("An example edit needs at least one field.")
        }
        var claim = document.interpretations[index]
        let changedText = edit.text.map { !$0.utf8.elementsEqual(source.text.utf8) } ?? false
        let kind = edit.sourceKind ?? (changedText ? "authored" : source.kind.rawValue)
        let input = NotebookCaptureExample(text: edit.text ?? source.text,
            translation: edit.translation ?? claim.translation,
            translationLanguage: edit.translationLanguage ?? claim.translationLanguage?.rawValue,
            completeness: edit.completeness ?? claim.completeness.rawValue, sourceKind: kind,
            ranges: edit.ranges ?? (changedText ? nil : occurrence.ranges.map { .init(location: $0.location, length: $0.length) }))
        let value = try NotebookCaptureFields.example(input, expression: entry.expression, id: claim.id, now: now)
        let changedSource = changedText || value.sourceKind != source.kind
        let changedOccurrence = changedSource || value.ranges != occurrence.ranges
        if changedSource {
            document.sources.append(.init(id: sourceID, text: value.text, kind: value.sourceKind,
                appBundleIdentifier: nil, encounteredAt: now))
        }
        if changedOccurrence {
            document.occurrences.append(.init(id: occurrenceID, sourceID: changedSource ? sourceID : source.id, ranges: value.ranges))
            claim.occurrenceID = occurrenceID
        }
        if changedOccurrence || value.completeness != claim.completeness {
            claim.explanations = []; claim.meaning = ""; claim.meaningLanguage = nil
        }
        claim.translation = value.translation; claim.translationLanguage = value.translationLanguage
        let primary = VocabularyMeaning(text: value.translation, language: value.translationLanguage)
        claim.translationVariants.removeAll { $0 == primary }
        claim.completeness = value.completeness
        if let citation = edit.source { claim.provenance.source = try NotebookCaptureFields.text(citation, limit: 4_096) }
        document.interpretations[index] = claim
    }

    public static func remove(_ ids: [UUID], senseID: UUID, from document: inout VocabularyDocument) throws {
        let selected = Set(ids)
        guard selected.count == ids.count, selected.allSatisfy({ id in
            document.interpretations.contains { $0.id == id && $0.senseID == senseID && $0.status == .accepted }
        }) else { throw NotebookToolError(code: .notFound, message: "An example does not belong to this sense.") }
        document.interpretations.removeAll { selected.contains($0.id) }
    }

    private static func addTranslation(_ text: String, language: LearningLanguage?, to claim: inout VocabularyInterpretation) {
        guard !text.isEmpty else { return }
        if claim.translation.isEmpty { claim.translation = text; claim.translationLanguage = language; return }
        let variant = VocabularyMeaning(text: text, language: language)
        if variant != .init(text: claim.translation, language: claim.translationLanguage), !claim.translationVariants.contains(variant) {
            claim.translationVariants.append(variant)
        }
    }
}
