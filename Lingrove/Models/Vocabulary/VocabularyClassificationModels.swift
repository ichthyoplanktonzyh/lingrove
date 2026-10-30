import LingroveNotebook
import Foundation

/// The archive owns this independent directory above meaning nodes. Membership never changes
/// lexical senses or collections; a portable snapshot carries the directory and local edits together.
typealias VocabularyClassificationIndex = LingroveNotebook.VocabularyClassificationIndex

/// A version receipt belongs to the notebook, so opening an older app cannot downgrade its catalog.
typealias VocabularyClassificationFramework = LingroveNotebook.VocabularyClassificationFramework

/// Categories describe reusable content or communicative functions. A built-in key is stable
/// across translations and catalog releases; authorship remains independent of catalog ownership.
typealias VocabularyCategory = LingroveNotebook.VocabularyCategory

/// A classification example illustrates a domain, rather than collecting a lexical sense.
/// It lives with its category and has no notebook membership, review state or evidence identity.
/// Its language tag describes source text without selecting or expanding a learning backend.
typealias VocabularyCategoryExample = LingroveNotebook.VocabularyCategoryExample

/// Locale-specific presentation belongs to the same stable category. String language tags are
/// independent of study languages (the interface also supports Indonesian and Turkish). Partial
/// custom translations inherit missing fields; examples and source references stay untranslated.
typealias VocabularyCategoryLocalization = LingroveNotebook.VocabularyCategoryLocalization

/// A source mapping explains how an authored category uses an external domain. Combined and
/// narrower mappings deliberately avoid claiming that Lingrove reproduces an external ontology.
/// References travel with portable category data so CLI consumers can inspect the evidence.
typealias VocabularyCategoryReference = LingroveNotebook.VocabularyCategoryReference

/// Explicit edges support several parents without duplicating the category or its meanings.
/// Catalog edges are replaced on upgrade; user edges survive and may only connect custom children.
typealias VocabularyCategoryParent = LingroveNotebook.VocabularyCategoryParent

/// A meaning can belong to several categories. This is directory membership, not a claim that
/// one expression realizes another meaning, and has no personal learning or review state.
typealias VocabularyMeaningCategoryMembership = LingroveNotebook.VocabularyMeaningCategoryMembership

/// One local overlay per category preserves renamed labels, descriptions and visibility while
/// bundled definitions evolve. Empty optional values mean inherit; an empty definition can clear it.
typealias VocabularyCategoryOverride = LingroveNotebook.VocabularyCategoryOverride
