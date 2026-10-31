# Shared notebook code

This package shares Lingrove's existing portable notebook graph between the Mac and iOS apps.
It contains document values and their joined editing projection, deterministic data rules,
snapshot/backup contracts, SQLite and PNG storage, and a text reading component. The app still
owns transaction orchestration, catalog resources, generation sessions and the complete editor.

## Ownership and data flow

`LingroveTextRules` contains Foundation-only Unicode safety and UTF-16 range checks shared by
autocomplete and notebook validation. Neither feature needs the other's domain to perform these
checks. The App's insertion gate delegates to the same predicate, retaining newline/punctuation
handling and rejecting replacement/control characters.

`LingroveNotebook` uses Foundation, the text rules, and built-in CryptoKit for stable identity.
`VocabularyContentBlock` carries an ordered block's
identity and either text formatting or an image reference with a caption. `VocabularyTextContent`
keeps the existing paragraph, heading and bullet styles. `VocabularyImageReference` carries
immutable dimensions and hash-based media identity; `VocabularyPreparedImage` pairs that identity
with draft bytes until the archive saves them. Neither type decodes images or writes files.

`VocabularyTextRange` preserves the existing UTF-16 location and length. Code that also owns the
source text remains responsible for validating string boundaries. Changing the coordinate unit
here would invalidate saved occurrence highlights.

`VocabularyDocument` keeps lexical catalog records, immutable sources and occurrences,
interpretation claims, personal collections, semantic relationships and classification as
separate tables of values. `VocabularyNotebookProjection` is the single adapter to the joined
entry/sense shape used by existing editors. Removing a collection does not delete its evidence;
changing an editor projection uses the same reconciliation code on either platform.

`LearningLanguage` supplies stable saved language codes. The host adds language names,
NaturalLanguage recognition and segmentation. Saved explanation inputs/results/records cross
the module boundary without a generation protocol, provider or running model. Semantic and
classification values include their provenance and optional overlays; bundled catalog loading
remains an app responsibility. Lifecycle, semantic, classification, localization-overlay and
content rules run in the shared core. Whole-document preparation and persisted review-receipt
checks are shared too; catalog installation and the commit's IO remain host-owned.

`VocabularyIdentityPolicy` preserves normalization, UTF-8 length framing and SHA-256 lookup keys.
Both App capture reconciliation and SQLite unique-key mapping call it; the storage target does
not maintain a second identity algorithm. Saved-explanation validation has the existing byte
ceilings, independent of prompt rendering or a model's token budget.

`VocabularyExplanationIdentity` constructs that saved input from notebook values or a host capture
adapter. `VocabularyDocumentValidation.validate` checks the complete graph without IO;
`prepare` preserves the Mac commit's ordered reconciliation and stale-explanation pruning before
validation. Strict reads/imports reject stale data instead of silently repairing it. The host owns
the transaction baseline and persists that exact prepared candidate under its revision check.
`VocabularyReviewValidation` validates layouts and optional legacy tool receipts without requiring
an Anki connection. Their historical limits and UUID scopes remain unchanged.

Review plans, layouts, templates and receipts are part of the existing portable graph. They
retain Anki note identity and audio receipts without importing an Anki client, scheduler or
speech service. This local archive representation is not the cloud synchronization contract:
device-specific endpoint/profile/binding data requires an explicit transport projection.

`LingroveNotebookUI` depends on the value product and SwiftUI. Its main-actor
`VocabularyTextBlockView` borrows one text value and a font from its host. It preserves bullet
prefixes, emphasis, line spacing and text selection. The Mac host still chooses its existing
reading size; an iOS host can choose a Dynamic Type font without changing saved content.

The app's composition root continues to own its single store and archive. The archive returns a
`VocabularySnapshot` with its local revision and document; a view receives a saved value or an
editor's copy. Save passes values to the existing validated SQLite transaction. A
`VocabularyBackup` pairs the same document with referenced media bytes for explicit local backup
and restore. Neither contract opens a database or owns a second archive.

`LingroveNotebookPersistenceCodec` maps the complete graph to 29 persistence families. Immutable
typed rows expose an entity ID, parent, position, exact nullable indexes and lazily encoded payload;
typed equality ignores dictionary/set JSON ordering. Decode verifies identity, ownership, ordering
and index/payload agreement. Each host chooses physical tables and scope columns. This product
owns no SQL, files or network, and its local tool metadata must not become a remote wire payload.

`LingroveNotebookSync` maps the complete graph to explicit public wire entities, preserving
device-private tool state separately. It also verifies raw-byte read windows and validates the
resulting confirmed server shadow. The host owns download storage, pending local edits, account
adoption and the final atomic commit; see the [wire contract](../../docs/NOTEBOOK_SYNC_CONTRACT.md)
and [native integration evidence](../../docs/NIBOMO_INTEGRATION.md#原生读取窗口校验与-sqlite-暂存).

`LingroveNotebookStorage` owns the Mac SQLite connections, schema migration, private
file locks and PNG normalization/verification. Its public database is an ordinary non-Sendable
class held by the archive actor; image storage also remains actor-owned. Production consumers
cannot access the C connection or schema helpers. The synchronous `access` closure
lets media staging and the SQL commit share one cross-process lock without suspending or
transferring ownership. Persistent revision checks, WAL/FULL durability, regular-file identity
and the existing schema version 5 remain unchanged. CLI receipts commit atomically with rows.
Code-only diagnostic callbacks keep the App's logger outside this target.

A cold backup/export first allows catalog installation before acquiring its shared media lock.
Inside that lock it reads the current committed snapshot without attempting another installation;
the file-lock rule still refuses a shared-to-exclusive upgrade. This preserves snapshot/media
consistency even if another process commits between preparation and the read lock.

Internal type aliases in the Mac model files keep existing callers on the shared representation.
Consumers explicitly import this package when accessing its members. Public initializers preserve
the old memberwise parameter order and defaults because Swift does not export a synthesized
memberwise initializer from a public struct. `VocabularyError` keeps decoding and storage failures
on one typed boundary; its existing messages use the host's `Vocabulary` localization table.

## Compatibility and validation

The extraction preserves field names, enum payloads, defaults, mutability, UUIDs and PNG filenames.
Golden serialization tests use the previous representation rather than just testing a new
encoder against its own decoder. Complete fixtures were generated by a frozen historical encoder
and are bundled test resources. Comparisons normalize only known unordered review dictionaries
and sets, preserving the order of content, evidence, labels and relationships. Tests cover v7 to
v8 decoding, missing classification guidance, absent versus empty values, collection ownership,
stored explanations and local review receipts. Mac archive and notebook tests cover integration
separately. Storage tests copy and reopen a real schema-5 fixture written by the checkpoint's old
implementation, then check revisions, receipts, rollback, file identity, lock nesting and PNG
isolation. Fixture provenance is retained alongside the synthetic test data.
The package declares macOS 14 and iOS 18; cross-compilation alone does not establish runtime or
accessibility compatibility on those minimum systems.

The [mobile plan](../../docs/MOBILE_NOTEBOOK_PLAN.md) tracks the remaining extraction and platform
work. The [source map](../../SOURCE_LAYOUT.md) documents responsibilities that still belong to the
Mac app.
The [Nibomo integration](../../docs/NIBOMO_INTEGRATION.md) describes the maintained downstream
source and use of shared Core/Codec values with Nibomo's own database/transaction owner.
