import Foundation
import Testing
@testable import LingroveNotebook

struct VocabularyClassificationReadIndexTests {
    @Test func diamondTaxonomyKeepsUniqueConfirmedMembershipsAndMatchesPolicy() {
        let categories = (0..<4).map { VocabularyCategory(id: UUID(), axis: .content, labels: [.init(text: "Category \($0)")]) }
        let nodes = [UUID(), UUID(), UUID()]
        var classification = VocabularyClassificationIndex()
        classification.categories = categories
        classification.parents = [.init(id: UUID(), categoryID: categories[1].id, parentID: categories[0].id),
            .init(id: UUID(), categoryID: categories[2].id, parentID: categories[0].id),
            .init(id: UUID(), categoryID: categories[3].id, parentID: categories[1].id),
            .init(id: UUID(), categoryID: categories[3].id, parentID: categories[2].id)]
        classification.memberships = [.init(id: UUID(), nodeID: nodes[0], categoryID: categories[3].id),
            .init(id: UUID(), nodeID: nodes[0], categoryID: categories[1].id),
            .init(id: UUID(), nodeID: nodes[1], categoryID: categories[2].id),
            .init(id: UUID(), nodeID: nodes[2], categoryID: categories[0].id)]
        classification.memberships[3].provenance.status = .proposed
        let read = VocabularyClassificationReadIndex(classification)
        for category in categories {
            #expect(read.descendants(of: category.id) == VocabularyClassificationPolicy.descendants(of: category.id, in: classification))
            #expect(read.meaningIDs(in: category.id) == VocabularyClassificationPolicy.meaningIDs(in: category.id, index: classification))
        }
        #expect(read.meaningIDs(in: categories[0].id) == Set(nodes.prefix(2)))
    }
}
