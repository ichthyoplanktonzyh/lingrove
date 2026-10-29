import Foundation
import Testing
@testable import Lingrove

/// The editor's value draft and archive transaction share this test surface. These cases
/// protect task completeness and cancellation without opening the developer's real notebook.
@MainActor
@Suite(.serialized)
struct VocabularyMeaningWorkflowTests {
    private func fixture() throws -> VocabularyDocument {
        var document = VocabularySemanticTests.fixture()
        try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: document.semantics.nodes)
        return document
    }

    @Test func functionContextCreatesTheCorrectNodeMappingAndMembership() throws {
        let document = try fixture()
        let category = try #require(document.classification.categories.first { $0.key == "function.social.greet" })
        let senseID = document.entries[0].senses[1].id
        let draft = VocabularyMeaningDraft(semantics: document.semantics, classification: document.classification,
            categoryID: category.id, senseID: senseID, languages: [.chinese])
        #expect(draft.original.kind == .function && draft.categoryIDs == [category.id])
        let result = draft.indexes(title: "问候", definition: "打招呼", kind: draft.original.kind)
        let mapping = try #require(result.semantics.mappings.first { $0.nodeID == draft.original.id })
        #expect(mapping.senseID == senseID && mapping.relation == .realizesFunction)
        #expect(result.classification.memberships.contains { $0.nodeID == draft.original.id && $0.categoryID == category.id })
        try VocabularySemanticPolicy.validate(result.semantics, entries: document.entries)
        try VocabularyClassificationPolicy.validate(result.classification, nodes: result.semantics.nodes)
    }

    @Test func oneSaveCommitsNewMeaningExpressionsAndDraftCategoryAtOneRevision() async throws {
        let document = try fixture(), archive = VocabularyArchive(url: nil)
        let first = try await archive.commit(document)
        var draft = VocabularyMeaningDraft(semantics: document.semantics, classification: document.classification,
            senseID: document.entries[0].senses[0].id, languages: [.chinese])
        let custom = VocabularyClassificationTests.category("自定义时间分类")
        draft.classification.categories.append(custom); draft.categoryIDs = [custom.id]
        // Child pickers work on the detached value; cancelling this task cannot publish it.
        #expect(try await archive.load().document == document)
        let values = draft.indexes(title: "重新安排", definition: "", kind: .concept)
        let saved = try await archive.updateMeaningOrganization(values.semantics, basedOn: draft.semanticBaseline,
            classification: values.classification, basedOn: draft.classificationBaseline)
        #expect(saved.revision == first.revision + 1)
        #expect(saved.document.classification.categories.contains(custom))
        #expect(saved.document.semantics.nodes.contains { $0.id == draft.original.id })
        #expect(saved.document.entries == document.entries)
        #expect(saved.document.classification.memberships.contains { $0.categoryID == custom.id && $0.nodeID == draft.original.id })
    }

    @Test func classificationConflictCannotPartiallySaveTheMeaning() async throws {
        let document = try fixture(), archive = VocabularyArchive(url: nil)
        _ = try await archive.commit(document)
        let category = document.classification.categories[0]
        var draft = VocabularyMeaningDraft(semantics: document.semantics, classification: document.classification)
        draft.classification.overrides.append(.init(categoryID: category.id, definition: "Sheet change"))
        let values = draft.indexes(title: "Must not be saved", definition: "", kind: .concept)
        var concurrent = document.classification
        concurrent.overrides.append(.init(categoryID: category.id, definition: "Concurrent change"))
        let current = try await archive.updateClassification(concurrent, basedOn: document.classification)
        await #expect(throws: VocabularyError.editConflict) {
            try await archive.updateMeaningOrganization(values.semantics, basedOn: draft.semanticBaseline,
                classification: values.classification, basedOn: draft.classificationBaseline)
        }
        let after = try await archive.load()
        #expect(after.document == current.document && after.revision == current.revision)
    }

    @Test func invalidExpressionCannotLeaveADraftCategoryBehind() async throws {
        let document = try fixture(), archive = VocabularyArchive(url: nil)
        let before = try await archive.commit(document)
        var draft = VocabularyMeaningDraft(semantics: document.semantics, classification: document.classification, senseID: UUID())
        let custom = VocabularyClassificationTests.category("Only in the draft")
        draft.classification.categories.append(custom); draft.categoryIDs = [custom.id]
        let values = draft.indexes(title: "Invalid association", definition: "", kind: .concept)
        await #expect(throws: VocabularyError.self) {
            try await archive.updateMeaningOrganization(values.semantics, basedOn: draft.semanticBaseline,
                classification: values.classification, basedOn: draft.classificationBaseline)
        }
        let after = try await archive.load()
        #expect(after.document == before.document && after.revision == before.revision)
    }

    @Test func editingMembershipAndNamePreservesEvidenceAndConcurrentIndependentWork() async throws {
        let document = try fixture(), archive = VocabularyArchive(url: nil)
        _ = try await archive.commit(document)
        let category = document.classification.categories[0], node = document.semantics.nodes[0]
        var draft = VocabularyMeaningDraft(semantics: document.semantics, classification: document.classification,
            node: node, languages: [.chinese])
        draft.categoryIDs = [category.id]
        let values = draft.indexes(title: "新的名称", definition: node.definition, kind: .function)
        var independent = document.classification
        let extra = VocabularyClassificationTests.category("Concurrent category"); independent.categories.append(extra)
        _ = try await archive.updateClassification(independent, basedOn: document.classification)
        let saved = try await archive.updateMeaningOrganization(values.semantics, basedOn: draft.semanticBaseline,
            classification: values.classification, basedOn: draft.classificationBaseline)
        #expect(saved.document.classification.categories.contains(extra))
        #expect(saved.document.semantics.mappings == document.semantics.mappings)
        #expect(saved.document.semantics.nodes[0].kind == node.kind)
        #expect(saved.document.semantics.nodes[0].roles == node.roles)
        #expect(saved.document.semantics.nodes[0].title == "新的名称")
    }
}
