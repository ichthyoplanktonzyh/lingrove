import Foundation

/// A sheet turns its detached indexes into record-level expectations once. The archive passes
/// this short-lived value to the writer, which applies it to its own latest validated document.
/// Unedited records are absent from the command and can change independently while a sheet is open.
public nonisolated struct VocabularyOrganizationEdit: Sendable {
    let semantic: Semantic?
    let classification: Classification?

    public init(semantics: VocabularySemanticIndex, basedOn baseline: VocabularySemanticIndex) throws {
        semantic = try Semantic(edited: semantics, baseline: baseline)
        classification = nil
    }

    public init(classification: VocabularyClassificationIndex, basedOn baseline: VocabularyClassificationIndex) throws {
        semantic = nil
        self.classification = try Classification(edited: classification, baseline: baseline)
    }

    public init(semantics: VocabularySemanticIndex, semanticBaseline: VocabularySemanticIndex,
                classification: VocabularyClassificationIndex, classificationBaseline: VocabularyClassificationIndex) throws {
        semantic = try Semantic(edited: semantics, baseline: semanticBaseline)
        self.classification = try Classification(edited: classification, baseline: classificationBaseline)
    }

    public func applying(semantics: VocabularySemanticIndex, classification: VocabularyClassificationIndex) throws
        -> (semantics: VocabularySemanticIndex, classification: VocabularyClassificationIndex) {
        let nextSemantic = try semantic?.applying(to: semantics) ?? semantics
        var nextClassification = try self.classification?.applying(to: classification) ?? classification
        if semantic != nil, self.classification == nil {
            let removed = Set(semantics.nodes.map(\.id)).subtracting(nextSemantic.nodes.map(\.id))
            nextClassification.memberships.removeAll { removed.contains($0.nodeID) }
        }
        return (nextSemantic, nextClassification)
    }

    struct Semantic: Sendable {
        let nodes: VocabularyRecordEdit<VocabularyMeaningNode>
        let patterns: VocabularyRecordEdit<VocabularyUsagePattern>
        let mappings: VocabularyRecordEdit<VocabularyMeaningMapping>
        let relations: VocabularyRecordEdit<VocabularyMeaningRelation>
        let cues: VocabularyRecordEdit<VocabularyRetrievalCue>
        let targets: VocabularyRecordEdit<VocabularyCueTarget>

        init(edited: VocabularySemanticIndex, baseline: VocabularySemanticIndex) throws {
            nodes = try .init(edited.nodes, baseline.nodes)
            patterns = try .init(edited.patterns, baseline.patterns)
            mappings = try .init(edited.mappings, baseline.mappings)
            relations = try .init(edited.relations, baseline.relations)
            cues = try .init(edited.cues, baseline.cues)
            targets = try .init(edited.cueTargets, baseline.cueTargets)
        }

        func applying(to current: VocabularySemanticIndex) throws -> VocabularySemanticIndex {
            try .init(nodes: nodes.applying(to: current.nodes, allowingMissingRemoval: true),
                patterns: patterns.applying(to: current.patterns, allowingMissingRemoval: true),
                mappings: mappings.applying(to: current.mappings, allowingMissingRemoval: true),
                relations: relations.applying(to: current.relations, allowingMissingRemoval: true),
                cues: cues.applying(to: current.cues, allowingMissingRemoval: true),
                cueTargets: targets.applying(to: current.cueTargets, allowingMissingRemoval: true))
        }
    }

    struct Classification: Sendable {
        let categories: VocabularyRecordEdit<VocabularyCategory>
        let parents: VocabularyRecordEdit<VocabularyCategoryParent>
        let memberships: VocabularyRecordEdit<VocabularyMeaningCategoryMembership>
        let overrides: VocabularyRecordEdit<VocabularyCategoryOverride>

        init(edited: VocabularyClassificationIndex, baseline: VocabularyClassificationIndex) throws {
            let builtIns = Set(baseline.categories.filter { $0.frameworkID != nil }.map(\.id))
            guard edited.frameworks == baseline.frameworks,
                  edited.categories.filter({ $0.frameworkID != nil }) == baseline.categories.filter({ $0.frameworkID != nil }),
                  edited.parents.filter({ builtIns.contains($0.categoryID) }) ==
                    baseline.parents.filter({ builtIns.contains($0.categoryID) }) else { throw VocabularyError.invalidContent }
            categories = try .init(edited.categories, baseline.categories)
            parents = try .init(edited.parents, baseline.parents)
            memberships = try .init(edited.memberships, baseline.memberships)
            overrides = try .init(edited.overrides, baseline.overrides)
        }

        func applying(to current: VocabularyClassificationIndex) throws -> VocabularyClassificationIndex {
            try .init(frameworks: current.frameworks, categories: categories.applying(to: current.categories),
                parents: parents.applying(to: current.parents), memberships: memberships.applying(to: current.memberships),
                overrides: overrides.applying(to: current.overrides))
        }
    }
}

/// Both organization domains share this linear merge. Stable IDs provide lookup, while the
/// current array retains presentation order. Each changed record carries its original value,
/// so a concurrent edit to that same record still fails under the writer's transaction.
nonisolated struct VocabularyRecordEdit<Value: Identifiable & Equatable & Sendable>: Sendable where Value.ID == UUID {
    private let updates: [(before: Value?, after: Value)]
    private let removals: [Value]

    var changedIDs: Set<UUID> { Set(updates.map { $0.after.id } + removals.map(\.id)) }

    init(_ edited: [Value], _ baseline: [Value]) throws {
        guard Set(edited.map(\.id)).count == edited.count,
              Set(baseline.map(\.id)).count == baseline.count else { throw VocabularyError.invalidContent }
        if edited == baseline {
            updates = []; removals = []
            return
        }
        let before = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        let present = Set(edited.map(\.id))
        updates = edited.compactMap { before[$0.id] == $0 ? nil : (before[$0.id], $0) }
        removals = baseline.filter { !present.contains($0.id) }
    }

    func applying(to current: [Value], allowingMissingRemoval: Bool = false) throws -> [Value] {
        guard !updates.isEmpty || !removals.isEmpty else { return current }
        guard Set(current.map(\.id)).count == current.count else { throw VocabularyError.invalidContent }
        let live = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for before in removals {
            guard live[before.id] == before || allowingMissingRemoval && live[before.id] == nil else {
                throw VocabularyError.editConflict
            }
        }
        for update in updates {
            guard live[update.after.id] == update.before || live[update.after.id] == update.after else {
                throw VocabularyError.editConflict
            }
        }
        let removed = Set(removals.map(\.id))
        let replacements = Dictionary(uniqueKeysWithValues: updates.map { ($0.after.id, $0.after) })
        var result = current.compactMap { removed.contains($0.id) ? nil : replacements[$0.id] ?? $0 }
        result += updates.filter { live[$0.after.id] == nil }.map(\.after)
        return result
    }
}
