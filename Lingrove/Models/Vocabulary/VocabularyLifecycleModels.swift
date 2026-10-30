import LingroveNotebook
import Foundation

/// An interpretation is a claim about one occurrence, not the occurrence itself. The archive
/// retains competing claims and unresolved material; only accepted, sense-linked claims become
/// example cards. External agents manage these values through the same validated CLI transaction.
typealias VocabularyInterpretation = LingroveNotebook.VocabularyInterpretation

/// A local user's relationship to one sense owns learning state and selected interpretations.
/// Removing this value never deletes linguistic knowledge or evidence. It has the sense's UUID
/// as its key because a local notebook has exactly one personal collection, not multiple users.
typealias VocabularyCollectionItem = LingroveNotebook.VocabularyCollectionItem
