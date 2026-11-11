import Foundation
import LingroveNotebook

/// Names every input that can change visible graph content. Selection, hover, camera, drawer
/// width and appearance settings are presentation state and deliberately do not enter this key.
/// The window supplies a store revision, never a content hash computed while SwiftUI renders.
nonisolated struct VocabularyGraphProjectionKey: Equatable, Sendable {
    let revision: UUID
    let language: LearningLanguage?
    let tag: String
    let query: String
    let expanded: Set<UUID>
    let isMeaningGraph: Bool
    let kind: VocabularyMeaningNode.Kind?
    let includeEmpty: Bool
    let languages: [LearningLanguage]
    let showsUnexplored: Bool
}
