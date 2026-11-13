# Certified cold single-entry writes

Status: accepted, 2026-11-13.

The subsequent [ADR 0007](0007-local-reviewed-source-retirement.md) extends certified sense
retirement to review consumers. The conservative reviewed-capture fallback remains.

ADR 0005 made pages and details available before complete reconstruction. A first favorite or
sense retirement still paid full decode, relationship validation and UI read-index preparation.
That proof cannot simply be skipped: entry keys and IDs are global, evidence can be shared,
media ownership can change independently, and review material can consume a changed sense.

## Decision

The engine owns a derived `notebook_entry_checkpoint` row per workspace. A complete checked
load/commit records notebook identity, revision, generation, schema version, trigger epoch/corpus
clock, a separately versioned validation contract, and the complete document media reference set.
The canonical change clock excludes this derived row. A checksum and deterministic encoding
detect damage to its media payload. The row is neither public content nor a UI-supplied proof.

A fresh writer may use this certificate only at its exact fence. `NotebookEntryAdmission` checks
indexed global identity/key ownership and detects evidence outside the selected subtree, review
consumers and cross-sense citations. The existing lossless codec and domain validator check the
target entry and its evidence closure. Missing/stale/damaged proof returns to complete preparation;
an identity conflict or invalid fragment remains an error. A warmed complete writer retains its
existing incremental path and complete cache.

`LingroveNotebookEngine+LocalEntry` owns this synchronous transaction from admission through
commit. It reuses the established row writer, revision CAS and pending journal. Canonical rows,
header, journal and replacement certificate commit or roll back together. It rechecks *all*
document media ownership/metadata/pins using the certificate's complete reference set even for
a text-only edit: media registry changes are not necessarily corpus changes. Cancellation is
checked before admission and immediately before writes; there is no suspension inside the SQL
transaction.

The scoped command returns `LingroveNotebookEntryCommit`, containing its exact fence and one
changed owner. It never installs its local validation fragment as a complete engine cache.
`VocabularyArchive+EntryCommands` attempts the restricted command and otherwise invokes the
ordinary full command. The store admits the receipt against the current corpus fence, updates
operation identity and refreshes pages/detail/favorite status. `entries`, read index and complete
snapshot remain absent until a complete consumer explicitly loads them. A complete load racing
receipt admission must receive a fresh complete document. Repository notifications follow
admission, preventing the store's own metadata installation from queuing a redundant full load.

The store retains at most the latest entry receipt for immediate explanation adoption. It clears
that value when its fence changes. The browse model and notebook view retire deleted selections
using the receipt's previous canonical/alias IDs without a full alias lookup.

## Admission limits

This stage supports ordinary text captures, appending a new accepted example, and sense
retirement without material consumers or foreign semantic citations. Existing source evidence
remains retained when a sense or last entry is removed; only owned mapping/pattern records are
retired, and shared meaning nodes remain.

Full preparation still owns:

- a missing certificate, external canonical changes, account/generation or schema/policy changes;
- enrolled/note-consuming senses, including consumers of a merged alias;
- changing the image reference set, authored ordering or an existing accepted interpretation;
- evidence referenced outside the selected entry and foreign citations affected by retirement;
- broader imports, structural changes, graph/search/export and other complete consumers.

An existing database without a certificate needs one complete preparation before a later cold
command can reuse it. Sync/raw writers that do not seal a new certificate conservatively revoke
it through the canonical clock. Supporting more producers/shapes is separate work, not permission
to treat a stale certificate or a visible page as a complete proof.

## Failure and metadata semantics

Version reads remain independent of payload reconstruction. The alias/plan lookup indexes use
`CASE WHEN json_valid(...)` before evaluating JSON expressions, so damaged payloads do not make
an unrelated metadata query or raw recovery fixture fail during index maintenance. Ordinary
load/save still rejects invalid canonical content. This is deliberate layering, not weaker
validation. Adding universal database JSON constraints would be a separate storage/recovery
contract, rather than an incidental side effect of a performance index.

## Validation

Generated private databases exercise cold append/retirement, retained sources and graph nodes,
global IDs/keys, reviewed-source fallback, missing/damaged/schema-stale proof, generation fences,
media changes outside the corpus clock, cancellation and journal failure rollback. Native tests
exercise the store/archive seam, page refresh, explanation adoption and a later complete load.
Release benchmarks distinguish eligible cold operations from enrolled and missing-proof fallback.
They use synthetic copies and a private app host, never the installed Dev app or its real data.
