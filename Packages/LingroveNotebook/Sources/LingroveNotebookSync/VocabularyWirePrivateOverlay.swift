import Foundation
import LingroveNotebook

/// A materialization owns its overlay copy. Unconsumed state is returned to the
/// host; it never recreates deleted public plans or silently transfers receipts
/// to a different UUID. Values are not encoded as part of a public projection.
nonisolated enum VocabularyWirePrivateOverlay {
    typealias State = VocabularyWirePrivateState
    typealias C = VocabularyWireCoding

    static func capture(_ document: VocabularyDocument, notebookID: UUID) throws -> State {
        var reviews: [State.Review] = [], explanations: [State.Explanation] = []
        func explanation(_ value: LearningExplanationRecord, owner: UUID, kind: VocabularyWireEntityKind) throws -> State.Explanation {
            .init(ownerKind: kind, ownerID: owner, explanationID: value.id, inputSignature: try C.signature(C.input(value.input)), occurrenceIdentity: value.input.occurrenceIdentity)
        }
        func review(_ value: VocabularyReview, sense: UUID, role: State.Role) throws -> State.Review? {
            var audio: [State.Audio] = []
            if let receipts = value.plan.audioReceipts {
                audio.append(.init(planID: value.plan.id, preservedIndex: nil, materialSignature: try C.signature(C.plan(value.plan)), receipts: receipts))
            }
            for (index, plan) in value.preservedPlans.enumerated() {
                if let receipts = plan.audioReceipts {
                    audio.append(.init(planID: plan.id, preservedIndex: index, materialSignature: try C.signature(C.plan(plan)), receipts: receipts))
                }
            }
            guard !value.bindings.isEmpty || value.activeBindingID != nil || !audio.isEmpty else { return nil }
            return .init(senseID: sense, role: role, bindings: value.bindings, activeBindingID: value.activeBindingID, audio: audio)
        }
        for entry in document.catalog {
            for sense in entry.senses {
                explanations += try sense.explanations.map { try explanation($0, owner: sense.id, kind: .senseExplanation) }
            }
        }
        for claim in document.interpretations {
            explanations += try claim.explanations.map { try explanation($0, owner: claim.id, kind: .interpretationExplanation) }
        }
        for collection in document.collections {
            if let value = collection.review, let local = try review(value, sense: collection.senseID, role: .legacy) { reviews.append(local) }
            for value in collection.reviewCards ?? [] {
                if let local = try review(value, sense: collection.senseID, role: .card(value.plan.id)) { reviews.append(local) }
            }
        }
        return .init(notebookID: notebookID, reviews: reviews, explanations: explanations)
    }

    static func apply(_ original: State, to document: inout VocabularyDocument) throws -> State {
        var aliases: [UUID: UUID] = [:]
        for sense in document.catalog.flatMap(\.senses) {
            for key in [sense.id] + sense.mergedFrom {
                guard aliases.updateValue(sense.id, forKey: key) == nil else { throw VocabularyWireError.invalidDocument }
            }
        }
        var reviews = original.reviews, explanations = original.explanations
        func restoreReview(_ value: VocabularyReview, senseID: UUID, role: State.Role) throws -> VocabularyReview {
            let matches = reviews.indices.filter { aliases[reviews[$0].senseID] == senseID && reviews[$0].role == role }
            // A prior materialization may have left only stale audio for this
            // same review. That remainder is not another binding owner and must
            // not reset the user's active choice on the next round trip.
            let bindingMatches = matches.filter { !reviews[$0].bindings.isEmpty || reviews[$0].activeBindingID != nil }
            var result = value, bindings: [AnkiNoteBinding] = [], seen: [UUID: AnkiNoteBinding] = [:]
            var bindingConflict = false
            for index in bindingMatches {
                for binding in reviews[index].bindings {
                    if let prior = seen[binding.id] {
                        if prior != binding { bindingConflict = true }
                    } else { seen[binding.id] = binding; bindings.append(binding) }
                }
            }
            if !bindingConflict {
                result.bindings = bindings
                if bindingMatches.count == 1, let index = bindingMatches.first { result.activeBindingID = reviews[index].activeBindingID }
                else {
                    // Restoring private state is not a new tool-selection action.
                    // Merged aliases may agree on a choice, but an explicit nil
                    // or competing choices must continue to require a choice.
                    let choices = Set(bindingMatches.compactMap { reviews[$0].activeBindingID })
                    result.activeBindingID = bindingMatches.allSatisfy({ reviews[$0].activeBindingID != nil }) && choices.count == 1
                        ? choices.first : nil
                }
                for index in bindingMatches { reviews[index].bindings = []; reviews[index].activeBindingID = nil }
            }
            func restoreAudio(_ plan: ReviewPlan, position: Int?) throws -> ReviewPlan {
                let signature = try C.signature(C.plan(plan))
                let candidates = matches.flatMap { index in
                    reviews[index].audio.indices.compactMap { audioIndex -> (Int, Int)? in
                        let audio = reviews[index].audio[audioIndex]
                        return audio.planID == plan.id && audio.materialSignature == signature ? (index, audioIndex) : nil
                    }
                }
                guard !candidates.isEmpty else { return plan }
                let preferred = candidates.filter { reviews[$0.0].senseID == senseID && reviews[$0.0].audio[$0.1].preservedIndex == position }
                let chosen: [(Int, Int)]
                if preferred.count == 1 { chosen = preferred }
                else {
                    guard let first = candidates.first else { return plan }
                    let receipts = reviews[first.0].audio[first.1].receipts
                    guard candidates.allSatisfy({ reviews[$0.0].audio[$0.1].receipts == receipts }) else { return plan }
                    chosen = candidates
                }
                guard let first = chosen.first else { return plan }
                var restored = plan; restored.audioReceipts = reviews[first.0].audio[first.1].receipts
                // Remove in descending local index order; a candidate from an
                // earlier preserved plan must not shift a later removal target.
                for index in Set(chosen.map(\.0)) {
                    let positions = Set(chosen.filter { $0.0 == index }.map(\.1))
                    reviews[index].audio = reviews[index].audio.enumerated().filter { !positions.contains($0.offset) }.map(\.element)
                }
                return restored
            }
            result.plan = try restoreAudio(result.plan, position: nil)
            for index in result.preservedPlans.indices { result.preservedPlans[index] = try restoreAudio(result.preservedPlans[index], position: index) }
            return result
        }
        for index in document.collections.indices {
            let sense = document.collections[index].senseID
            if let value = document.collections[index].review { document.collections[index].review = try restoreReview(value, senseID: sense, role: .legacy) }
            if var cards = document.collections[index].reviewCards {
                for card in cards.indices { cards[card] = try restoreReview(cards[card], senseID: sense, role: .card(cards[card].plan.id)) }
                document.collections[index].reviewCards = cards
            }
        }

        let joined = document.entries
        var owners: [UUID: VocabularySense] = [:]
        for entry in joined { for sense in entry.senses { owners[sense.id] = sense } }
        func withIdentity(_ record: LearningExplanationRecord, _ identity: String?) -> LearningExplanationRecord {
            let input = record.input
            let replaced = LearningExplanationInput(target: input.target, dictionaryForm: input.dictionaryForm, language: input.language,
                kind: input.kind, context: input.context, ranges: input.ranges, contextKind: input.contextKind, occurrenceIdentity: identity)
            return .init(id: record.id, input: replaced, language: record.language, result: record.result, model: record.model, createdAt: record.createdAt)
        }
        func restoreExplanation(_ record: LearningExplanationRecord, ownerID: UUID, kind: VocabularyWireEntityKind,
                                derived: String?, strict: Bool) throws -> LearningExplanationRecord {
            let signature = try C.signature(C.input(record.input))
            let matches = explanations.indices.filter { index in
                let value = explanations[index]
                let owner = kind == .senseExplanation ? aliases[value.ownerID] : value.ownerID
                return value.ownerKind == kind && owner == ownerID && value.explanationID == record.id && value.inputSignature == signature
            }
            var identity = derived
            if !strict, let first = matches.first {
                let local = explanations[first].occurrenceIdentity
                if matches.allSatisfy({ explanations[$0].occurrenceIdentity == local }) { identity = local }
                else { return withIdentity(record, derived) }
            }
            let consumed = Set(matches)
            explanations = explanations.enumerated().filter { !consumed.contains($0.offset) }.map(\.element)
            return withIdentity(record, identity)
        }
        for entry in document.catalog.indices {
            for sense in document.catalog[entry].senses.indices {
                let value = document.catalog[entry].senses[sense], owner = owners[value.id]
                let identity = VocabularyExplanationIdentity.generalIdentity(for: owner)
                document.catalog[entry].senses[sense].explanations = try value.explanations.map {
                    try restoreExplanation($0, ownerID: value.id, kind: .senseExplanation, derived: identity, strict: true)
                }
            }
        }
        for index in document.interpretations.indices {
            let claim = document.interpretations[index]
            let example = claim.senseID.flatMap { owners[$0]?.examples.first { $0.id == claim.id } }
            document.interpretations[index].explanations = try claim.explanations.map { record in
                let identity: String?
                if let example { identity = VocabularyIdentityPolicy.exampleKey(example) }
                else if record.input.contextKind == .none {
                    identity = VocabularyExplanationIdentity.generalIdentity(for: claim.senseID.flatMap { owners[$0] })
                } else {
                    let completeness: VocabularyExample.Completeness = switch record.input.contextKind {
                    case .sentence: .sentence
                    case .fragment: .fragment
                    case .unknown, .none: .unknown
                    }
                    identity = VocabularyIdentityPolicy.exampleKey(.init(id: claim.id, text: record.input.context, translation: "", translationLanguage: nil,
                        ranges: record.input.ranges, completeness: completeness, meaning: "", meaningLanguage: nil, appBundleIdentifier: nil, createdAt: record.createdAt))
                }
                return try restoreExplanation(record, ownerID: claim.id, kind: .interpretationExplanation, derived: identity, strict: claim.status == .accepted)
            }
        }
        return .init(notebookID: original.notebookID,
            reviews: reviews.filter { !$0.bindings.isEmpty || $0.activeBindingID != nil || !$0.audio.isEmpty }, explanations: explanations)
    }
}
