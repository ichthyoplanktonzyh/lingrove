# Lingrove notebook engine

This package is the portable SQLite and built-in review core extracted from the mobile
checkpoint `9351fd93b697a145ded9ded6bb008420b864b5d8` (which includes `e523fc81`). It reuses
`LingroveNotebook` graph values, persistence codec, wire rules, text rules, PNG storage and
study export. It contains no UI, authentication service, network runner, timers or default
guest session. A native Mac app can import `LingroveNotebookEngine` without creating
`LocalDatabase` or `FlashcardsStore`.

## Ownership and data flow

`LingroveNotebookEngine` is the host facade. The owning initializer takes an explicit SQLite
URL and media directory; the borrowing initializer takes an existing `DatabaseCore`. A mobile
`LocalDatabase` creates one borrowed facade alongside its existing connection, and forwards
its corpus, Card, review and sync-persistence operations to it. Closing a borrowed facade does
not close the host connection. Closing the owner retires that connection and every late call
fails through the same guarded Core. Neither initializer discovers a bundle, user directory,
endpoint or running application.

`DatabaseCore` owns the SQLite handle, prepared statement lifetimes and one recursive lock.
Its write pool leases at most 64 idle prepared statements, keyed by literal SQL bytes (including
Unicode spelling). Successful execution resets the statement and clears bindings before reuse;
failed statements are finalized, SQLite v2 handles schema recompilation, and close finalizes the
pool. Idle bindings retain no payload values, and statements never cross connection ownership.
The lock survives connection close; a synchronous transaction holds it across BEGIN, all
borrowed stores and COMMIT/ROLLBACK. Its raw handle is internal. Public execute/query access
exists for the mobile schema initializer and coordinated legacy stores, not for a network
runner. Hosts serialize the non-Sendable facade on their own owner; no lock or transaction
may span an `await`. The package retains the mobile Swift 5 language mode while exporting
Sendable snapshots/bindings/commands already used across task boundaries.

The owning initializer creates schema 39, including Card scheduling, corpus, journal, private
snapshot, media, staging and review tables. It also upgrades the immediately preceding live
schema 38 in one transaction, adding the optional material recipe and review-media table without
rewriting corpus, authored Card faces or ratings. Other unsupported versions fail without erasing
or rewriting data. A borrowing host must adopt this schema through its own reviewed initializer.
There is one SQLite truth, not a JSON mirror or separate review database.

| Responsibility | Files and collaborators | Flow and invariant |
| --- | --- | --- |
| Corpus | `Persistence/NotebookStore/LingroveNotebookStore.swift`, `LingroveNotebookSyncStore.swift` | snapshot + local revision/generation → prepared graph → same-transaction rows, media registration, journal and generated material refresh; stale CAS rolls back all of them |
| Account and local scope | `LingroveNotebookAccountStore`, `LingroveNotebookLocalScopeStore`, `Commands/*Accounts.swift` | trusted owner/workspace plus explicit retain/accept command → durable scopes/proposals → user-chosen adoption; login alone does not copy or upload local content |
| Download windows | `LingroveNotebookWindowStore` | scope + generation → raw-byte staging → verified window; completion alone changes neither visible corpus nor cursor |
| Upload, conflict, retry | upload/staged/closure/terminal/retry/conflict stores | local journal → frozen bounded public request → exact receipt/rejection → rebase/apply; later edits and unsent operations remain pending |
| Media | media and media queue stores | validated PNG bytes in injected root → workspace authorization map/pins → durable queued/claimed/control state; live leases and pending journal/ownership references prevent premature cleanup |
| Review admission | `Commands/*LingroveNotebookReview.swift`, Card/link/enrollment stores | explicit saved sense draft → one transaction for enrollment, Card, provenance, hold and journals; collect/prepare alone never enrolls |
| Review resource ownership | `LingroveNotebookReviewMediaStore` | prepared PNG/WAV/MP3 bytes → validated workspace-owned SQLite rows + native asset metadata in the same save transaction; no pre-save file publication or legacy media upload |
| Material refresh | `LingroveNotebookReviewMaterialStore`, `LingroveNotebookCardMaterial` | old generated + current authored + new source material → field-wise three-way update; literal UTF-8 spelling preserves manual ownership; scheduling/history are untouched |
| Scheduling and queue | `Review/Scheduling`, `Review/Queue`, Card read/write SQL | current persisted Card + settings + rating → existing FSRS-6 schedule; queue ordering, strict timestamps and timezone rules remain the mobile implementation |
| Rating, undo, history | `Commands/*Review.swift`, `*NotebookUndo.swift`, `Review/Sync` | immutable rating event and schedule journal commit together; undo targets the persisted causal schedule head and restores scheduling fields while retaining authored faces and history |
| Queries and statistics | `Queries`, `Review/Statistics` | bounded Card/deck/queue/history queries over the same connection; the Card scheduling snapshot is truth, never reconstructed from review history |

The extracted `Card`, `Deck`, `ReviewEvent`, scheduler settings, Card sync payload and review
wire types keep their existing names and fields. `Models/Notebook/NotebookAccountValues.swift`
contains only the immutable account/settings values required by storage; credentials and
provider/session behavior remain in the app/cloud package. `Review/Sync/LingroveNotebookReviewWire.swift`
is the single pure review codec used by SQLite and the mobile network adapter.

## Native host entry points

```swift
import LingroveNotebookEngine

let engine = try LingroveNotebookEngine(databaseURL: databaseURL, mediaDirectoryURL: mediaURL)
let saved = try engine.loadLingroveNotebook(workspaceId: workspaceID)
let notes = try engine.enrollReviewNotes(selections: [selection],
    type: ReviewNoteDefaults.type, scope: saved)
```

Native screens retain the saved `LingroveNotebookSnapshot` alongside their Note/type draft.
Use `enrollReviewNotes`, `saveReviewNote`, `saveReviewNoteType` and the built-in rating/status/undo
commands so their transactions check the exact source, question and durable generation.
An account/workspace ABA switch cannot grant an old callback a new lifetime. Generic Card/FSRS
persistence remains infrastructure; it does not create notebook enrollment or a Note association.

The typed stores expose B's required stages without a network dependency: capture/check
`LingroveNotebookWindowBinding`; pending/next/frozen upload/control; prepare/commit apply;
record exact receipt/rejection; staged pages/closure/retry; media enqueue/claim/complete/control/
pin/prune; review request/apply with typed `LingroveNotebookReviewRequest/Response`. Network
code must freeze/encode data while borrowing these synchronous boundaries and release them
before waiting for HTTP. A failed review lane does not change the corpus cursor. B-to-A port
adapters and app lifecycle wiring belong to the integration checkpoint, not this package.

## Shared Note authoring and practice

`LingroveNotebook/ReviewNotes` owns Note fields, Note Types, templates, projection and rendering.
`ReviewNoteStore` persists definitions, source/example bindings, custom fields and stable
Note × Template membership. `enrollReviewNotes` creates all members in one source-scoped
transaction; source, Note or type edits refresh affected members without changing FSRS/history.
The Card projection and its baseline compare literal stored bytes, including Unicode encoding.

Native queue, participation, history and Progress accept only Note-owned Cards. Source loss
marks material `sourceMissing`; it does not delete the Note/Card or its future rating history.
Pausing/withdrawing changes participation, while ratings/undo remain Card-owned. Source images
are validated against workspace ownership and registered as bounded review media atomically.
Native reads use exact saved-context transactions and never fetch a source URL while rendering.

The per-exercise recipe writers, direct Card preparation/editing, retained-face override and
recipe refresh were removed on 2026-11-14. The user waived existing legacy card content/history
compatibility; no migration or dual runtime is provided. Historical corpus codec DTOs are not
native authoring interfaces. Dynamic gap generation and audio/video preparation are outside
this cleanup's Note capability scope.

## Review wire version 3

The held review lane synchronizes Note/type/member/default definitions and exact operation ACKs
through `LingroveNotebookReviewRequest/Response` v3. Definition changes fence stale question
ratings and retain changes made during an in-flight request. Pending owned media is sent first
as one bounded item with an exact digest acknowledgement; a later envelope carries dependent
Card/link operations. Unsupported versions, missing media acknowledgements and malformed scoped
state fail without retiring pending work. Network calls remain outside SQLite transactions.

The independent backend/mobile repository adopts reviewed shared snapshots separately. Mac
package tests demonstrate local storage/codec/adapter behavior and do not claim deployment or
physical-device validation. See `docs/REPOSITORY_BOUNDARIES.md` for repository ownership.

## Validation and provenance

The package tests open real temporary SQLite files and close/reopen them. Existing mobile
storage, source/deletion, journal/ACK/rebase, media pin and review suites run directly against
the portable facade. Existing FSRS parity cases use the exact checked-in vector bytes. New
boundary cases cover independent media roots, borrowed connection lifetime, cancellation,
scoped account ABA rejection, explicit ownership/history adoption and exact review ACK while
a newer rating remains pending. Native host compilation and affected native module checks
are recorded in `docs/MAC_WORKSPACE.md`; package tests do not claim a real provider,
server or dual-device journey.

The extraction manifest maps source files to their new responsibility boundary. Original
Nibomo code is MIT (Kirill Markin, 2026), retained in `LICENSE`. The scheduler mirrors official
`ts-fsrs` 5.2.3 / Open Spaced Repetition; its MIT notice is retained under `LICENSES/`.
See `Nibomo/docs/fsrs-scheduling-logic.md` for the product parity contract. This extraction
does not change FSRS parameters, formulas, fuzzing, rebuild behavior or timezone policy.

The current schema includes `notebook_cli_receipts`, a bounded installation-local ledger for
Mac CLI batch acknowledgements. Its key cannot be reused in another workspace/owner/endpoint;
completed replies survive journal ACK and restart. The existing corpus writer and receipt share
one transaction through `saveNotebookCLI`; no receipt enters a public journal. Unsupported
development schema snapshots are not migrated or erased.

### Focused mobile consumers

An entry editor can retain `NotebookEntryDetail` and submit it through the detail overload of
`saveNotebookEntry`. The engine compares the durable corpus clock inside either the certified
writer or the fully validated fallback. A partial detail is never accepted as a complete document.
`notebookEntries(lookupKeys:expected:)` resolves batch owners in one frozen read transaction.
An all-new batch of at most 100 entries uses `VocabularyEntryAppendChange`, a proof produced
only by the checked domain state. One mutable preparation checks each member against the
preceding members, then the codec encodes the final lexical suffix and appended evidence once.
This avoids repeating large value copies for every imported word. Existing-owner and mixed
batches use `VocabularyEntryBatchChange`: one mutable ownership index/document still checks
and reconciles each member in input order, then the codec compares only the final affected
groups. Explicit manual creation continues to add a new sense under an existing headword;
matching wording never silently deduplicates that user action. Merge undo retains its existing
single-owner reconciliation and owned-semantic restoration. All paths finish through the same
CAS, media, journal, review-material and receipt transaction. The caller's baseline supplies no
validation authority, and a failed member leaves the original state available for retry.

`notebookLiteralSearchMaterial` projects searchable scalar fields, accepted evidence and confirmed
meaning/cue/pattern joins without loading the full document or classification directory. A browser
actor owns this disposable material and pages frozen summary results. Reuse requires its exact
corpus fence and locale. Literal fields and semantic admission follow the shared browser rules;
retrieval neither creates relations nor establishes a writer's validation certificate.
Repeated fields share one immutable `NotebookSearchTextTable`. Per-term decision storage is
bounded by its distinct field count; multi-term searches progressively narrow the candidates.
ASCII-only operands use a linear byte matcher, while all non-ASCII or Turkic-locale cases keep
Foundation's existing localized comparison. `NotebookAcceptedSearchEvidence` owns a transient
accepted-use → occurrence → source join inside the pinned read transaction. Each table is read
in physical row order, and only referenced source payloads are decoded. Candidate uses remain
excluded and shared sources serve each admitted interpretation; transient rowids never leave
the transaction or enter persisted search metadata.
`prepareNotebookSearch` adds a rebuildable, workspace-owned projection in two private SQLite
metadata tables, excluded from canonical backup/sync and deleted with the workspace. Exact
schema/epoch/corpus/owner fences, checksum and bounded format-2 decoding admit a cache read.
Certified local-entry and checked complete/batch writers append one bounded transaction delta;
the journal is capped at 64 frames / 8 MiB, with at most 100 affected entries per frame. Readers
bound the journal before decoding, verify its complete consecutive fence/checksum chain, and
reuse a memory witness only when its exact fence belongs to that chain. They avoid reading the
large payload for an admitted memory witness and replay the required suffix with one text
builder/final ordering pass. A reader without memory verifies the persisted base and replays
the complete chain. Small edits retain the durable journal; a full projection checkpoint is
written after 8 frames or 512 KiB, outside the read transaction and with the same final CAS.
This amortizes encoding/fsync rather than moving full projection work into an editor's save.
Existing shared-evidence changes,
semantic changes, raw writes, missed
deltas, generation changes or corrupt data rebuild through the canonical scanner. This cache
is never a writer certificate. The first metadata installation conservatively invalidates an
older certificate; normal full validation re-establishes it before local writes resume.
The opt-in `NotebookSearchPerformanceTests` and `NotebookSearchProjectionScaleTests` copy supplied
closed synthetic exports. The latter distinguishes unprimed preparation, persisted reopen and
editing followed by search. Do not point either at an application database.

`notebookReviewQuestion` reads one Note/type/source and only the images referenced by its rendered
faces. It returns a corpus fence, review clock and rating question token. Hosts recheck admission
after asynchronous work. Generic Cards return nil; unavailable Note sources fail explicitly.

`notebookNoteEditor` returns one Note/type with its canonical sense subtree, source fence and
review clock. `previewNotebookNote` checks the original Note/type and source again before
rendering ephemeral edits and reading only referenced images. The version-based Note/type
writers retain the same CAS, source refresh, atomic Card updates and history as complete callers;
an optional exact corpus token also rejects raw same-revision source changes. Complete and
selected review assembly share one implementation; no partial corpus snapshot is fabricated.

Note commands also offer `WithReceipt` variants. They retain the same transactional writer,
then return either one source group's review rows or a style-only definition. Presentation may
apply that patch only across its exact base/final review clocks and unchanged corpus fence;
concurrent ratings, enrollment and structural template changes use the complete reader. The
receipt marks the new local edit pending until ordinary acknowledgement reconciliation.
