import Foundation
import LingroveNotebook

extension VocabularyPersistenceRow {
    /// Call after typed payload equality. Swift String equality folds canonical Unicode;
    /// these leaf checks retain the author's exact bytes without JSON-encoding every unchanged
    /// source/claim/graph row twice. Structured history/layout payloads keep the codec fallback.
    /// This comparison does not validate or grant write authority to a row.
    func hasSameLiteralPayload(as other: Self) throws -> Bool {
        if let left = record.payload.literalParts, let right = other.record.payload.literalParts {
            guard left.numbers == right.numbers, left.text.count == right.text.count else { return false }
            return zip(left.text, right.text).allSatisfy { lhs, rhs in
                switch (lhs, rhs) {
                case (nil, nil): true
                case let (lhs?, rhs?): lhs.utf8.elementsEqual(rhs.utf8)
                default: false
                }
            }
        }
        return try encodedPayload() == other.encodedPayload()
    }
}

/// Only validated scalar row shapes use this fast path. Guards keep a malformed nested
/// header on the general comparison path; decoding still checks the complete row round trip.
private struct LiteralParts {
    let text: [String?]
    let numbers: [UInt64]
    init(_ text: [String?] = [], numbers: [UInt64] = []) { self.text = text; self.numbers = numbers }
}

private extension VocabularyDatabaseRecord.Payload {
    var literalParts: LiteralParts? {
        switch self {
        case let .entry(value) where value.senses.isEmpty:
            return .init([value.expression, value.dictionaryForm, value.language?.rawValue],
                numbers: [value.createdAt.timeIntervalSinceReferenceDate.bitPattern, value.updatedAt.timeIntervalSinceReferenceDate.bitPattern])
        case let .sense(value) where value.examples.isEmpty && value.explanations.isEmpty && value.content == nil &&
            value.review == nil && value.reviewCards == nil:
            return .init([value.meaning, value.meaningLanguage?.rawValue, value.note] + value.tags.map(Optional.some) +
                meaningText(value.standaloneMeanings) + meaningText(value.alternateMeanings),
                numbers: [value.createdAt.timeIntervalSinceReferenceDate.bitPattern, value.updatedAt.timeIntervalSinceReferenceDate.bitPattern,
                    value.savedAt?.timeIntervalSinceReferenceDate.bitPattern ?? 0])
        case let .source(value):
            return .init([value.text, value.appBundleIdentifier], numbers: [value.encounteredAt.timeIntervalSinceReferenceDate.bitPattern])
        case .occurrence, .roleBinding, .evidence, .categoryParent:
            return .init()
        case let .usage(value) where value.explanations.isEmpty:
            return .init([value.meaning, value.meaningLanguage?.rawValue, value.translation, value.translationLanguage?.rawValue,
                value.provenance.source] + meaningText(value.translationVariants),
                numbers: [value.createdAt.timeIntervalSinceReferenceDate.bitPattern, value.provenance.confidence?.bitPattern ?? 0])
        case let .collection(value) where value.content?.isEmpty != false && value.review == nil && value.reviewCards?.isEmpty != false:
            return .init([value.note] + value.tags.map(Optional.some), numbers: [value.savedAt?.timeIntervalSinceReferenceDate.bitPattern ?? 0])
        case let .meaningNode(value) where value.labels.isEmpty && value.roles.isEmpty:
            return .init([value.definition, value.scopeNote, value.provenance.source],
                numbers: [value.createdAt.timeIntervalSinceReferenceDate.bitPattern, value.updatedAt.timeIntervalSinceReferenceDate.bitPattern,
                    value.provenance.confidence?.bitPattern ?? 0])
        case let .meaningLabel(value): return .init([value.text, value.language?.rawValue])
        case let .meaningRole(value): return .init([value.name, value.description])
        case let .usagePattern(value) where value.slots.isEmpty:
            return .init([value.template, value.region, value.note, value.provenance.source] + value.collocations.map(Optional.some),
                numbers: [value.provenance.confidence?.bitPattern ?? 0])
        case let .patternSlot(value): return .init([value.name, value.constraint])
        case let .meaningMapping(value) where value.roleBindings.isEmpty && value.evidenceIDs.isEmpty:
            return .init([value.conditions, value.nuance, value.provenance.source], numbers: [value.provenance.confidence?.bitPattern ?? 0])
        case let .meaningRelation(value): return .init([value.note, value.provenance.source], numbers: [value.provenance.confidence?.bitPattern ?? 0])
        case let .retrievalCue(value): return .init([value.text, value.language?.rawValue])
        case let .cueTarget(value): return .init([value.conditions, value.provenance.source], numbers: [value.provenance.confidence?.bitPattern ?? 0])
        case let .classificationFramework(value): return .init([value.key])
        case let .categoryMembership(value): return .init([value.provenance.source], numbers: [value.provenance.confidence?.bitPattern ?? 0])
        case let .block(value):
            switch value.content {
            case let .text(text): return .init([text.text])
            case let .image(image, caption): return .init([image.digest, caption])
            }
        default: return nil
        }
    }

    func meaningText(_ values: [VocabularyMeaning]) -> [String?] {
        values.flatMap { [$0.text, $0.language?.rawValue] }
    }
}
