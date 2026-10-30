import Foundation

/// Durable learning content is independent of translation requests and Anki. The app-owned
/// vocabulary store persists these values; cards supply immutable captures and never AX handles.
public nonisolated struct VocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case word, expression, pattern, sentence }
    public let id: UUID
    public var expression: String
    public var dictionaryForm: String
    /// Unknown source metadata stays nil; saving must never relabel a homograph as English.
    public let language: LearningLanguage?
    public let kind: Kind
    public var senses: [VocabularySense]
    public let createdAt: Date
    public var updatedAt: Date

    /// Read-only projections support headword-wide search and dictionary lookup. Storage and
    /// editing always name a sense; these projections never create a second owner of a usage.
    public var examples: [VocabularyExample] { senses.flatMap(\.examples) }
    public var explanations: [LearningExplanationRecord]? {
        let records = senses.flatMap { $0.explanations + $0.examples.flatMap(\.explanations) }
        var seen = Set<UUID>()
        let unique = records.filter { seen.insert($0.id).inserted }
        return unique.isEmpty ? nil : unique
    }

    public init(
        id: UUID,
        expression: String,
        dictionaryForm: String,
        language: LearningLanguage?,
        kind: Kind,
        senses: [VocabularySense],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.expression = expression
        self.dictionaryForm = dictionaryForm
        self.language = language
        self.kind = kind
        self.senses = senses
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A stable learning identity for one core meaning. Catalog records keep the lexical fields;
/// notebook projections overlay selected examples and personal notes/cards from independent
/// records. Rewording a summary never changes its UUID or its review/meaning-graph references.
public nonisolated struct VocabularySense: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var meaning: String
    public var meaningLanguage: LearningLanguage?
    public var meaningOrigin: VocabularyMeaningOrigin = .captured
    public var note = ""
    public var tags: [String] = []
    public var examples: [VocabularyExample] = []
    public var isSavedWithoutContext = false
    public var standaloneMeanings: [VocabularyMeaning] = []
    public var explanations: [LearningExplanationRecord] = []
    public var alternateMeanings: [VocabularyMeaning] = []
    public var mergedFrom: [UUID] = []
    /// Projected from the personal collection; absence is distinct from an empty draft.
    public var review: VocabularyReview?
    /// Flexible cards have independent review identities. Legacy review records are not migrated.
    public var reviewCards: [VocabularyReview]?
    public var content: [VocabularyContentBlock]?
    public let createdAt: Date
    public var updatedAt: Date
    /// Manual/imported meanings support general explanations independently of whether the
    /// personal collection claims the context-free favorite slot.
    public var createdWithoutContext: Bool?
    public var supportsGeneralExplanation: Bool { isSavedWithoutContext || createdWithoutContext == true }

    public init(
        id: UUID,
        meaning: String,
        meaningLanguage: LearningLanguage? = nil,
        meaningOrigin: VocabularyMeaningOrigin = .captured,
        note: String = "",
        tags: [String] = [],
        examples: [VocabularyExample] = [],
        isSavedWithoutContext: Bool = false,
        standaloneMeanings: [VocabularyMeaning] = [],
        explanations: [LearningExplanationRecord] = [],
        alternateMeanings: [VocabularyMeaning] = [],
        mergedFrom: [UUID] = [],
        review: VocabularyReview? = nil,
        reviewCards: [VocabularyReview]? = nil,
        content: [VocabularyContentBlock]? = nil,
        createdAt: Date,
        updatedAt: Date,
        createdWithoutContext: Bool? = nil
    ) {
        self.id = id
        self.meaning = meaning
        self.meaningLanguage = meaningLanguage
        self.meaningOrigin = meaningOrigin
        self.note = note
        self.tags = tags
        self.examples = examples
        self.isSavedWithoutContext = isSavedWithoutContext
        self.standaloneMeanings = standaloneMeanings
        self.explanations = explanations
        self.alternateMeanings = alternateMeanings
        self.mergedFrom = mergedFrom
        self.review = review
        self.reviewCards = reviewCards
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.createdWithoutContext = createdWithoutContext
    }
}

/// Window navigation and durable destinations use both levels. Sense IDs stay independent of
/// presentation order, labels and generated explanation language.
public nonisolated struct VocabularySelection: Equatable, Hashable, Sendable {
    public let entryID: UUID
    public let senseID: UUID

    public init(
        entryID: UUID,
        senseID: UUID
    ) {
        self.entryID = entryID
        self.senseID = senseID
    }
}

/// The archive records who owns a meaning, independently of its text. Model refreshes may
/// replace captured/AI drafts, while an explicit edit or adoption transfers ownership to the user.
public nonisolated enum VocabularyMeaningOrigin: String, Codable, Equatable, Sendable { case captured, ai, user }

/// A word can be saved without sentence context in several translation languages. Keep those
/// translations distinct instead of pretending they are full example-sentence translations.
public nonisolated struct VocabularyMeaning: Codable, Equatable, Identifiable, Sendable {
    public var text: String
    public let language: LearningLanguage?
    public var id: String { language?.rawValue ?? "unknown" }

    public init(
        text: String,
        language: LearningLanguage?
    ) {
        self.text = text
        self.language = language
    }
}

/// A joined example card: one accepted interpretation plus its immutable source occurrence.
/// Its ID names the interpretation, and optional occurrenceID distinguishes shared evidence.
/// Separated fixed parts use exact UTF-16 spans rather than a first-word text search.
public nonisolated struct VocabularyExample: Codable, Equatable, Identifiable, Sendable {
    /// Unknown boundaries are not evidence of missing text. Keep that distinction when a
    /// reading receipt becomes a saved usage; existing sentence/fragment archives retain their meaning.
    public enum Completeness: String, Codable, Sendable { case sentence, fragment, unknown }
    public enum SourceKind: String, Codable, Sendable { case unspecified, captured, authored, generated, imported }
    public let id: UUID
    public var sourceID = UUID()
    /// A displayed example is an accepted interpretation. Several candidate interpretations
    /// may refer to this same occurrence without copying the source or its UTF-16 spans.
    public var occurrenceID: UUID?
    public var sourceKind: SourceKind = .unspecified
    public var text: String
    public var translation: String
    public var translationLanguage: LearningLanguage?
    public var translationVariants: [VocabularyMeaning] = []
    public var ranges: [VocabularyTextRange]
    public var completeness: Completeness
    public var meaning: String
    public var meaningLanguage: LearningLanguage?
    public var meaningOrigin: VocabularyMeaningOrigin = .captured
    public var appBundleIdentifier: String?
    public let createdAt: Date
    public var explanations: [LearningExplanationRecord] = []

    public func copiedWithNewID() -> Self {
        .init(id: UUID(), sourceID: sourceID, sourceKind: sourceKind, text: text, translation: translation,
            translationLanguage: translationLanguage,
            translationVariants: translationVariants, ranges: ranges, completeness: completeness, meaning: meaning,
            meaningLanguage: meaningLanguage, meaningOrigin: meaningOrigin, appBundleIdentifier: appBundleIdentifier,
            createdAt: createdAt, explanations: explanations)
    }

    public init(
        id: UUID,
        sourceID: UUID = UUID(),
        occurrenceID: UUID? = nil,
        sourceKind: SourceKind = .unspecified,
        text: String,
        translation: String,
        translationLanguage: LearningLanguage? = nil,
        translationVariants: [VocabularyMeaning] = [],
        ranges: [VocabularyTextRange],
        completeness: Completeness,
        meaning: String,
        meaningLanguage: LearningLanguage? = nil,
        meaningOrigin: VocabularyMeaningOrigin = .captured,
        appBundleIdentifier: String? = nil,
        createdAt: Date,
        explanations: [LearningExplanationRecord] = []
    ) {
        self.id = id
        self.sourceID = sourceID
        self.occurrenceID = occurrenceID
        self.sourceKind = sourceKind
        self.text = text
        self.translation = translation
        self.translationLanguage = translationLanguage
        self.translationVariants = translationVariants
        self.ranges = ranges
        self.completeness = completeness
        self.meaning = meaning
        self.meaningLanguage = meaningLanguage
        self.meaningOrigin = meaningOrigin
        self.appBundleIdentifier = appBundleIdentifier
        self.createdAt = createdAt
        self.explanations = explanations
    }
}

/// One retained source snapshot can support multiple expression occurrences. The document and
/// SQLite own this evidence independently of interpretation and personal collection lifetimes.
public nonisolated struct VocabularySourceSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let kind: VocabularyExample.SourceKind
    public let appBundleIdentifier: String?
    public let encounteredAt: Date

    public init(
        id: UUID,
        text: String,
        kind: VocabularyExample.SourceKind,
        appBundleIdentifier: String?,
        encounteredAt: Date
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.appBundleIdentifier = appBundleIdentifier
        self.encounteredAt = encounteredAt
    }
}

/// UTF-16 spans name an occurrence in the source. A sense's usage annotation refers to this
/// identity; moving that annotation never changes the original characters or their positions.
public nonisolated struct VocabularySourceOccurrence: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceID: UUID
    public let ranges: [VocabularyTextRange]

    public init(
        id: UUID,
        sourceID: UUID,
        ranges: [VocabularyTextRange]
    ) {
        self.id = id
        self.sourceID = sourceID
        self.ranges = ranges
    }
}

/// The immutable notebook value is shared by UI snapshots, backup and JSON interchange. SQLite
/// stores its entities separately; this version describes the portable representation only.
public nonisolated struct VocabularyDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 8
    public var schemaVersion: Int
    /// Canonical lexical records contain no examples or personal learning state. The joined
    /// entries adapter below keeps existing editors independent of persistence relationships.
    public var catalog: [VocabularyEntry]
    public var sources: [VocabularySourceSnapshot]
    public var occurrences: [VocabularySourceOccurrence]
    public var interpretations: [VocabularyInterpretation]
    public var collections: [VocabularyCollectionItem]
    public var reviewTemplates: [ReviewLayoutTemplate]?
    public var semantics: VocabularySemanticIndex
    public var classification: VocabularyClassificationIndex

    public var entries: [VocabularyEntry] {
        get { VocabularyNotebookProjection.entries(self, collectedOnly: false) }
        set { VocabularyNotebookProjection.replace(newValue, in: &self) }
    }
    public var collectedEntries: [VocabularyEntry] { VocabularyNotebookProjection.entries(self, collectedOnly: true) }

    public init(schemaVersion: Int? = nil, entries: [VocabularyEntry] = [], reviewTemplates: [ReviewLayoutTemplate]? = nil,
         semantics: VocabularySemanticIndex = .init(), classification: VocabularyClassificationIndex = .init()) {
        self.schemaVersion = schemaVersion ?? Self.requiredVersion(for: entries)
        self.catalog = []; self.sources = []; self.occurrences = []; self.interpretations = []; self.collections = []
        self.reviewTemplates = reviewTemplates
        self.semantics = semantics
        self.classification = classification
        VocabularyNotebookProjection.replace(entries, in: &self)
    }

    public init(catalog: [VocabularyEntry], sources: [VocabularySourceSnapshot], occurrences: [VocabularySourceOccurrence],
         interpretations: [VocabularyInterpretation], collections: [VocabularyCollectionItem],
         reviewTemplates: [ReviewLayoutTemplate]? = nil, semantics: VocabularySemanticIndex = .init(),
         classification: VocabularyClassificationIndex = .init()) {
        schemaVersion = Self.currentVersion
        self.catalog = catalog; self.sources = sources; self.occurrences = occurrences
        self.interpretations = interpretations; self.collections = collections
        self.reviewTemplates = reviewTemplates; self.semantics = semantics
        self.classification = classification
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, catalog, sources, occurrences, interpretations, collections, reviewTemplates, semantics, classification
    }

    /// Version seven already has the canonical evidence/meaning graph. Upgrading adds an empty
    /// directory without synthesizing memberships or changing any existing identity or receipt.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 7 || version == Self.currentVersion else { throw VocabularyError.unsupportedVersion }
        schemaVersion = Self.currentVersion
        catalog = try values.decode([VocabularyEntry].self, forKey: .catalog)
        sources = try values.decode([VocabularySourceSnapshot].self, forKey: .sources)
        occurrences = try values.decode([VocabularySourceOccurrence].self, forKey: .occurrences)
        interpretations = try values.decode([VocabularyInterpretation].self, forKey: .interpretations)
        collections = try values.decode([VocabularyCollectionItem].self, forKey: .collections)
        reviewTemplates = try values.decodeIfPresent([ReviewLayoutTemplate].self, forKey: .reviewTemplates)
        semantics = try values.decode(VocabularySemanticIndex.self, forKey: .semantics)
        classification = version == 7 ? .init() : try values.decode(VocabularyClassificationIndex.self, forKey: .classification)
    }

    /// Optional language/context metadata does not change the portable format per document.
    public static func requiredVersion(for entries: [VocabularyEntry]) -> Int {
        currentVersion
    }
}

public nonisolated struct VocabularySnapshot: Sendable {
    public let revision: UInt64
    public let document: VocabularyDocument

    public init(
        revision: UInt64,
        document: VocabularyDocument
    ) {
        self.revision = revision
        self.document = document
    }
}
