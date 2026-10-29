import Foundation
import Testing
@testable import Lingrove

/// Exercise the same value interface used by sheets and CLI plans, including updates with
/// user extensions. Fixtures never probe the developer's installed notebook.
@MainActor
struct VocabularyClassificationTests {
    static func category(_ name: String, axis: VocabularyCategory.Axis = .content) -> VocabularyCategory {
        .init(id: UUID(), axis: axis, labels: [.init(text: name, language: .english)])
    }
    static func catalog(version: Int = 1, includesChild: Bool = true) -> VocabularyClassificationCatalog {
        .init(key: "test.core", version: version, authorship: "Fixture", references: [], categories:
            [.init(key: "degree", axis: .content, english: "Degree", chinese: "程度")] +
            (includesChild ? [.init(key: "near-zero", axis: .content, english: "Near absence", chinese: "接近于无", parents: ["degree"])] : []))
    }

    @Test func bundledCatalogHasStableMultilingualKeysAndSeparateAxes() throws {
        let catalog = try VocabularyClassificationCatalog.bundled()
        var index = VocabularyClassificationIndex()
        #expect(try catalog.install(in: &index, nodes: []))
        #expect(index.categories.count == 256)
        #expect(catalog.categories.filter { $0.parents.isEmpty && $0.axis == .content }.count == 20)
        #expect(catalog.categories.filter { $0.parents.isEmpty && $0.axis == .function }.count == 6)
        let category = try #require(index.categories.first { $0.key == "content.degree.near-zero" })
        #expect(VocabularyClassificationPolicy.title(category, in: index, languages: [.chinese]) == "接近于无")
        #expect(VocabularyClassificationPolicy.title(category, in: index, languages: [.english]) == "Near absence")
        let before = index
        #expect(try !catalog.install(in: &index, nodes: []))
        #expect(index == before)
    }

    @Test func multiParentCountsDeduplicateMeaningsAcrossPaths() throws {
        let root = Self.category("Root"), left = Self.category("Left"), right = Self.category("Right"), child = Self.category("Child")
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Meaning")])
        var index = VocabularyClassificationIndex(categories: [root, left, right, child], parents: [
            .init(id: UUID(), categoryID: left.id, parentID: root.id), .init(id: UUID(), categoryID: right.id, parentID: root.id),
            .init(id: UUID(), categoryID: child.id, parentID: left.id), .init(id: UUID(), categoryID: child.id, parentID: right.id)
        ], memberships: [.init(id: UUID(), nodeID: node.id, categoryID: child.id), .init(id: UUID(), nodeID: node.id, categoryID: left.id)])
        try VocabularyClassificationPolicy.validate(index, nodes: [node])
        #expect(VocabularyClassificationPolicy.meaningIDs(in: root.id, index: index) == [node.id])
        let rows = VocabularyClassificationProjection.rows(index, nodes: [node], languages: [.english], expanded: [], query: "Child")
        #expect(rows.filter { $0.category.id == child.id }.count == 2)
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.first?.meaningCount == 1)
        index.parents.append(.init(id: UUID(), categoryID: root.id, parentID: child.id))
        #expect(throws: VocabularyError.invalidContent) { try VocabularyClassificationPolicy.validate(index, nodes: [node]) }
    }

    @Test func duplicateLinksCrossAxisParentsAndOrphansAreRejected() throws {
        let parent = Self.category("Parent"), child = Self.category("Function", axis: .function)
        var index = VocabularyClassificationIndex(categories: [parent, child])
        index.parents = [.init(id: UUID(), categoryID: child.id, parentID: parent.id)]
        #expect(throws: VocabularyError.invalidContent) { try VocabularyClassificationPolicy.validate(index, nodes: []) }
        index.parents = []; index.memberships = [.init(id: UUID(), nodeID: UUID(), categoryID: parent.id)]
        #expect(throws: VocabularyError.invalidContent) { try VocabularyClassificationPolicy.validate(index, nodes: []) }
        index.memberships = []; index.overrides = [.init(categoryID: UUID(), isHidden: true)]
        #expect(throws: VocabularyError.invalidContent) { try VocabularyClassificationPolicy.validate(index, nodes: []) }
    }

    @Test func catalogUpgradeKeepsLocalNamesExtensionsMembershipsAndRetiredIDs() throws {
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Meaning")])
        var index = VocabularyClassificationIndex()
        try Self.catalog().install(in: &index, nodes: [node])
        let root = index.categories[0], child = index.categories[1], custom = Self.category("My category")
        index.categories.append(custom)
        index.parents.append(.init(id: UUID(), categoryID: custom.id, parentID: child.id))
        let membership = VocabularyMeaningCategoryMembership(id: UUID(), nodeID: node.id, categoryID: child.id)
        index.memberships.append(membership)
        let overlay = VocabularyCategoryOverride(categoryID: root.id, labels: [.init(text: "My degree")], definition: "My scope", isHidden: true)
        index.overrides.append(overlay)
        #expect(try Self.catalog(version: 2, includesChild: false).install(in: &index, nodes: [node]))
        #expect(index.categories.contains { $0.id == child.id && $0.isRetired })
        #expect(index.categories.contains(custom))
        #expect(index.memberships == [membership] && index.overrides == [overlay])
        #expect(VocabularyClassificationPolicy.effective(root, in: index).definition == "My scope")
        #expect(try !Self.catalog().install(in: &index, nodes: [node]))
        #expect(index.frameworks[0].version == 2)
    }

    @Test func deletingCustomCategoryKeepsMeaningAndDetachesChildren() throws {
        let parent = Self.category("Parent"), child = Self.category("Child")
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Meaning")])
        var index = VocabularyClassificationIndex(categories: [parent, child],
            parents: [.init(id: UUID(), categoryID: child.id, parentID: parent.id)],
            memberships: [.init(id: UUID(), nodeID: node.id, categoryID: parent.id)])
        try VocabularyClassificationPolicy.removeCategory(parent.id, from: &index)
        #expect(index.categories == [child] && index.parents.isEmpty && index.memberships.isEmpty)
        try VocabularyClassificationPolicy.validate(index, nodes: [node])
    }

    @Test func detachedDraftPreservesIndependentChangesAndRejectsSameRowConflicts() throws {
        let category = Self.category("Original"), other = Self.category("Independent")
        let baseline = VocabularyClassificationIndex(categories: [category])
        var edited = baseline; edited.categories[0].definition = "Draft"
        var current = baseline; current.categories.append(other)
        let merged = try VocabularyClassificationPolicy.merge(edited, baseline: baseline, current: current)
        #expect(merged.categories[0].definition == "Draft" && merged.categories.contains(other))
        current.categories[0].definition = "Concurrent"
        #expect(throws: VocabularyError.editConflict) { try VocabularyClassificationPolicy.merge(edited, baseline: baseline, current: current) }
    }

    @Test func versionSevenPortableDocumentUpgradesWithoutChangingEvidence() throws {
        let document = VocabularySemanticTests.fixture()
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        fields["schemaVersion"] = 7; fields.removeValue(forKey: "classification")
        let upgraded = try JSONDecoder().decode(VocabularyDocument.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(upgraded == document)
        fields["schemaVersion"] = 99
        #expect(throws: VocabularyError.unsupportedVersion) {
            try JSONDecoder().decode(VocabularyDocument.self, from: JSONSerialization.data(withJSONObject: fields))
        }
    }

    @Test func selectiveJSONCarriesOnlyRelevantCategoriesAndAncestors() throws {
        var document = VocabularySemanticTests.fixture()
        try Self.catalog().install(in: &document.classification, nodes: document.semantics.nodes)
        let child = document.classification.categories[1], unrelated = Self.category("Unrelated")
        document.classification.categories.append(unrelated)
        document.classification.memberships = [.init(id: UUID(), nodeID: document.semantics.nodes[0].id, categoryID: child.id)]
        let exported = VocabularyExportPolicy.document(document.entries, configuration: .init(format: .json),
            semantics: document.semantics, classification: document.classification)
        #expect(exported.version == 5)
        let classification = try #require(exported.classification)
        #expect(classification.categories.count == 2 && !classification.categories.contains(unrelated))
        try VocabularyClassificationPolicy.validate(classification, nodes: try #require(exported.semantics).nodes)
        let withoutMeanings = VocabularyExportPolicy.document(document.entries,
            configuration: .init(format: .json, meanings: false), semantics: document.semantics, classification: document.classification)
        #expect(withoutMeanings.classification == nil)
    }
}
