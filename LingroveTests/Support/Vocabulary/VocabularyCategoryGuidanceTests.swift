import Foundation
import Testing
@testable import Lingrove

/// Guidance belongs to category data, not learned vocabulary. These tests protect compatibility,
/// catalog upgrades, local overlays and portable persistence without touching the real notebook.
@MainActor
struct VocabularyCategoryGuidanceTests {
    @Test func bundledGuidanceIsCompleteAndTraceable() throws {
        let catalog = try VocabularyClassificationCatalog.bundled()
        #expect(catalog.version == 4)
        #expect(catalog.categories.count == 338)
        for category in catalog.categories {
            #expect(!category.definition.isEmpty)
            #expect(!(category.scopeNote ?? "").isEmpty)
            #expect(!(category.examples ?? []).isEmpty)
            let references = try #require(category.references)
            #expect(!references.isEmpty)
            #expect(references.contains { $0.source == "SIL Semantic Domains v4" })
            for reference in references where reference.source == "SIL Semantic Domains v4" {
                #expect(reference.url == "https://semdom.org/v4/" + reference.identifier + "/")
                #expect(reference.license == "CC-BY-SA-4.0")
                #expect(reference.attribution?.contains("SIL Global") == true)
            }
        }
        let nearZero = try #require(catalog.categories.first { $0.key == "content.degree.near-zero" })
        let threshold = try #require(catalog.categories.first { $0.key == "content.degree.threshold" })
        #expect(nearZero.references?.contains { $0.identifier == "A13.7" } == true)
        #expect(threshold.references?.contains { $0.identifier == "9.4.4.7" && $0.relationship == .narrower } == true)
        #expect(nearZero.definition != threshold.definition)
        var index = VocabularyClassificationIndex()
        try catalog.install(in: &index, nodes: [])
        #expect(index.memberships.isEmpty)
    }

    @Test func expandedDomainsPreserveDistinctRoutesAndDeduplicateSharedBranches() throws {
        let catalog = try VocabularyClassificationCatalog.bundled()
        var index = VocabularyClassificationIndex()
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Liquid movement")])
        try catalog.install(in: &index, nodes: [node])
        func category(_ key: String) throws -> VocabularyCategory {
            try #require(index.categories.first { $0.key == key })
        }
        let warming = try category("content.objects.process.warming"), heating = try category("content.actions.heating")
        #expect(warming.id != heating.id && warming.definition != heating.definition)
        #expect(warming.references.contains { $0.identifier == "8.3.4" })
        #expect(heating.references.contains { $0.identifier == "8.3.4" })
        let flow = try category("content.motion.flow")
        let motion = try category("content.motion"), process = try category("content.objects.process")
        #expect(Set(index.parents.filter { $0.categoryID == flow.id }.map(\.parentID)) == [motion.id, process.id])
        index.memberships = [.init(id: UUID(), nodeID: node.id, categoryID: flow.id)]
        #expect(VocabularyClassificationPolicy.meaningIDs(in: motion.id, index: index) == [node.id])
        #expect(VocabularyClassificationPolicy.meaningIDs(in: process.id, index: index) == [node.id])
        let conditional = try category("function.influence.refuse.conditional")
        let negotiation = try category("function.influence.negotiate"), acceptance = try category("function.influence.refuse")
        #expect(Set(index.parents.filter { $0.categoryID == conditional.id }.map(\.parentID)) == [negotiation.id, acceptance.id])
        #expect(conditional.references.contains { $0.identifier == "3.3.2.1" })
        #expect(conditional.references.contains { $0.identifier == "9.6.2.8" })
        #expect(try category("content.general.enablement.hinder").id != category("content.general.enablement.prevent").id)
        try VocabularyClassificationPolicy.validate(index, nodes: [node])
    }

    @Test func legacyCategoryAndOverlayDecodeWithoutGuidance() throws {
        let category = VocabularyClassificationTests.category("Old category")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(category)) as? [String: Any])
        for key in ["examples", "scopeNote", "references", "localizations"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(VocabularyCategory.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == category)
        let overlay = VocabularyCategoryOverride(categoryID: category.id, definition: "Local")
        let data = try JSONEncoder().encode(overlay)
        #expect(try JSONDecoder().decode(VocabularyCategoryOverride.self, from: data) == overlay)
    }

    @Test func sourceMappedCatalogUpgradeKeepsIDsMembershipsAndLocalGuidance() throws {
        let catalog = try VocabularyClassificationCatalog.bundled()
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any])
        old["version"] = 1
        let categories = try #require(old["categories"] as? [[String: Any]])
        old["categories"] = categories.prefix(256).map { row in
            var row = row
            row["definition"] = ""
            for key in ["examples", "scopeNote", "references", "localizations"] { row.removeValue(forKey: key) }
            return row
        }
        let legacy = try JSONDecoder().decode(VocabularyClassificationCatalog.self,
            from: JSONSerialization.data(withJSONObject: old))
        let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Meaning")])
        var index = VocabularyClassificationIndex()
        try legacy.install(in: &index, nodes: [node])
        let originalIDs = Set(index.categories.map(\.id)), id = index.categories[0].id
        let custom = VocabularyClassificationTests.category("Custom")
        index.categories.append(custom)
        let overlay = VocabularyCategoryOverride(categoryID: id, definition: "Local definition",
            examples: [.init(text: "local illustration", language: "en")], scopeNote: "Local scope")
        index.overrides.append(overlay)
        let membership = VocabularyMeaningCategoryMembership(id: UUID(), nodeID: node.id, categoryID: id)
        index.memberships.append(membership)
        #expect(try catalog.install(in: &index, nodes: [node]))
        #expect(originalIDs.isSubset(of: Set(index.categories.map(\.id))))
        #expect(index.categories.contains(custom))
        #expect(index.memberships == [membership] && index.overrides == [overlay])
        let upgraded = try #require(index.categories.first { $0.id == id })
        #expect(!upgraded.examples.isEmpty && !upgraded.references.isEmpty)
        let effective = VocabularyClassificationPolicy.effective(upgraded, in: index)
        #expect(effective.definition == "Local definition" && effective.scopeNote == "Local scope")
        #expect(effective.examples == overlay.examples && effective.references == upgraded.references)
        let before = index
        #expect(try !catalog.install(in: &index, nodes: [node]))
        #expect(index == before)
    }

    @Test func guidanceSurvivesSQLiteAndSelectiveExportWithoutCreatingVocabulary() throws {
        let database = try VocabularySQLiteDatabase(url: nil)
        var document = VocabularySemanticTests.fixture()
        try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: document.semantics.nodes)
        let category = try #require(document.classification.categories.first { $0.key == "content.motion.arrival" })
        document.classification.memberships = [.init(id: UUID(), nodeID: document.semantics.nodes[0].id, categoryID: category.id)]
        let oldEntries = document.entries, oldSemantics = document.semantics
        _ = try database.write(document, previous: .init(), expectedRevision: 0)
        let decoded = try database.read().document
        #expect(decoded == document)
        #expect(decoded.entries == oldEntries && decoded.semantics == oldSemantics)
        let selected = VocabularyClassificationPolicy.selected(decoded.classification, nodes: decoded.semantics.nodes)
        #expect(selected.categories.contains(category))
        let data = try JSONEncoder().encode(selected)
        #expect(try JSONDecoder().decode(VocabularyClassificationIndex.self, from: data) == selected)
        var invalid = decoded.classification
        invalid.categories[0].examples = [.init(text: " ", language: "en")]
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyClassificationPolicy.validate(invalid, nodes: decoded.semantics.nodes)
        }
        invalid = decoded.classification
        invalid.categories[0].references[0].url = "javascript:alert(1)"
        #expect(throws: VocabularyError.invalidContent) {
            try VocabularyClassificationPolicy.validate(invalid, nodes: decoded.semantics.nodes)
        }
    }
}
