import LingroveNotebook
import Foundation

/// The archive owns this durable meaning index alongside lexical entries. These value types
/// cross the actor boundary as one immutable snapshot; neither a list nor a graph owns a copy
/// that can be edited independently. Labels are language-specific, identities are not.
typealias VocabularySemanticIndex = LingroveNotebook.VocabularySemanticIndex

/// A content concept answers "what is meant"; a communicative function answers "what the
/// speaker is doing". Keeping the distinction prevents a request from becoming a synonym of
/// the event requested. Nodes can exist before any expression has been collected for them.
typealias VocabularyMeaningNode = LingroveNotebook.VocabularyMeaningNode

/// Preferred names and aliases describe one node. Ambiguous search phrases live in cues,
/// whose many-to-many targets deliberately do not assert equivalence with the node.
typealias VocabularyMeaningLabel = LingroveNotebook.VocabularyMeaningLabel

typealias VocabularyMeaningRole = LingroveNotebook.VocabularyMeaningRole

/// A pattern belongs to exactly one sense. Its slots describe syntax, while node roles
/// describe meaning; a mapping may explicitly connect the two without equating their names.
typealias VocabularyUsagePattern = LingroveNotebook.VocabularyUsagePattern

typealias VocabularyPatternSlot = LingroveNotebook.VocabularyPatternSlot

/// This is a claim, not an ownership relationship: several senses may realize one meaning,
/// and one sense may participate in several meanings. A pattern restriction narrows the claim;
/// deleting it must never silently broaden the claim to the entire sense.
typealias VocabularyMeaningMapping = LingroveNotebook.VocabularyMeaningMapping

typealias VocabularyRoleBinding = LingroveNotebook.VocabularyRoleBinding

/// Relations are explicitly authored. Similar wording, embedding proximity and shared labels
/// never create an edge. `narrower` points from the more specific node to its broader parent.
typealias VocabularyMeaningRelation = LingroveNotebook.VocabularyMeaningRelation

typealias VocabularyRetrievalCue = LingroveNotebook.VocabularyRetrievalCue

typealias VocabularyCueTarget = LingroveNotebook.VocabularyCueTarget

/// Authorship and adoption are independent: confirmed means usable in the notebook, not
/// necessarily reviewed by a human. Authorized agent writes retain model origin and are adopted
/// by default; explicit uncertainty and invalidated evidence can still produce proposed claims.
typealias VocabularySemanticProvenance = LingroveNotebook.VocabularySemanticProvenance
