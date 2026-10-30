import Foundation
import LingroveNotebook

/// Durable learning content is independent of translation requests and Anki. The app-owned
/// vocabulary store persists these values; cards supply immutable captures and never AX handles.
typealias VocabularyEntry = LingroveNotebook.VocabularyEntry

/// A stable learning identity for one core meaning. Catalog records keep the lexical fields;
/// notebook projections overlay selected examples and personal notes/cards from independent
/// records. Rewording a summary never changes its UUID or its review/meaning-graph references.
typealias VocabularySense = LingroveNotebook.VocabularySense

/// Window navigation and durable destinations use both levels. Sense IDs stay independent of
/// presentation order, labels and generated explanation language.
typealias VocabularySelection = LingroveNotebook.VocabularySelection

/// The archive records who owns a meaning, independently of its text. Model refreshes may
/// replace captured/AI drafts, while an explicit edit or adoption transfers ownership to the user.
typealias VocabularyMeaningOrigin = LingroveNotebook.VocabularyMeaningOrigin

/// A word can be saved without sentence context in several translation languages. Keep those
/// translations distinct instead of pretending they are full example-sentence translations.
typealias VocabularyMeaning = LingroveNotebook.VocabularyMeaning

/// A joined example card: one accepted interpretation plus its immutable source occurrence.
/// Its ID names the interpretation, and optional occurrenceID distinguishes shared evidence.
/// Separated fixed parts use exact UTF-16 spans rather than a first-word text search.
typealias VocabularyExample = LingroveNotebook.VocabularyExample

/// One retained source snapshot can support multiple expression occurrences. The document and
/// SQLite own this evidence independently of interpretation and personal collection lifetimes.
typealias VocabularySourceSnapshot = LingroveNotebook.VocabularySourceSnapshot

/// UTF-16 spans name an occurrence in the source. A sense's usage annotation refers to this
/// identity; moving that annotation never changes the original characters or their positions.
typealias VocabularySourceOccurrence = LingroveNotebook.VocabularySourceOccurrence

/// The shared range retains the existing archive keys and UTF-16 units. The
/// app alias lets capture, validation and editors keep naming the same value.
typealias VocabularyTextRange = LingroveNotebook.VocabularyTextRange

/// Short-lived card input. It is copied with the displayed sentence, so saving never rereads
/// whichever editor happens to be focused after the user clicks a nonactivating card.
nonisolated struct VocabularyCapture: Equatable, Sendable {
    let expression: String
    let dictionaryForm: String
    /// Unknown source metadata stays nil; saving must never relabel a homograph as English.
    let language: LearningLanguage?
    let kind: VocabularyEntry.Kind
    var meaning = ""
    var meaningLanguage: LearningLanguage?
    var example: VocabularyExample?
    var explanation: LearningExplanationRecord?
    /// Supplied only by an explicit notebook destination, never by model-generated text.
    var senseID: UUID?
    /// Explicit notebook senses have a local receipt independent of text equality. Floating
    /// captures leave it nil; this identity is never included in the model's prompt.
    var generalExplanationIdentity: String?
    /// Staged lookup already owns an interpreted pair. Legacy full-result enrichment must not
    /// replace its meaning with an older cached interpretation while saving that sentence translation.
    var allowsExplanationEnrichment = true
}

/// The immutable notebook value is shared by UI snapshots, backup and JSON interchange. SQLite
/// stores its entities separately; this version describes the portable representation only.
typealias VocabularyDocument = LingroveNotebook.VocabularyDocument

typealias VocabularySnapshot = LingroveNotebook.VocabularySnapshot

/// Storage destination is separate from semantic input: two saved translations can share one
/// explanation while still owning independently editable meanings.
nonisolated struct VocabularyExplanationDestination: Equatable, Sendable {
    let entryID: UUID
    let senseID: UUID
    let exampleID: UUID?
}
