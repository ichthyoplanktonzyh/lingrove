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
let draft = try LingroveNotebookCardMaterial.draft(snapshot: saved, selection: selection)
let enrollment = try engine.enrollNotebookSenses([draft], basedOn: saved)
```

Native screens retain the saved `LingroveNotebookSnapshot` alongside their draft. Use
`enrollNotebookSenses(_:basedOn:)`, `setNotebookReviewStatus(_:enrollments:basedOn:requestID:)`
and `submitNotebookRating(_:basedOn:expectedCardOperationID:)` so the transaction checks the
durable generation even after an account/workspace ABA switch. Preparation/retain/undo and
source save likewise use their snapshot or generation fence. Old mobile labels remain thin
compatibility entry points; they do not contain another operation body.

The typed stores expose B's required stages without a network dependency: capture/check
`LingroveNotebookWindowBinding`; pending/next/frozen upload/control; prepare/commit apply;
record exact receipt/rejection; staged pages/closure/retry; media enqueue/claim/complete/control/
pin/prune; review request/apply with typed `LingroveNotebookReviewRequest/Response`. Network
code must freeze/encode data while borrowing these synchronous boundaries and release them
before waiting for HTTP. A failed review lane does not change the corpus cursor. B-to-A port
adapters and app lifecycle wiring belong to the integration checkpoint, not this package.

## Shared review material

`LingroveNotebook.ReviewMaterialPlan` owns an ordered `ReviewLayout`, stable selected example,
optional name and typed audio descriptors. It contains no Anki deck, field mapping, filename or
receipt. `ReviewMaterialResolver` reads saved entry/sense values and resolves text, content blocks,
gap prompts and audio kinds identically for both targets. Anki chooses safe HTML; the engine's
`LingroveNotebookCardMaterial.render(entry:sense:plan:workspaceID:)` chooses safe native Markdown
and scoped `fcasset:` IDs. Source text is escaped before markup; custom block formatting remains
explicit. Audio hashes exact source UTF-8 bytes, so a changed expression/sentence requires fresh
recording rather than silently playing an old one.

A draft and durable `LingroveNotebookCardLink.materialPlan` retain that recipe. Create, prepare,
retained edit, source refresh, remote apply, card-ID repair and explicit account ownership copy
preserve it. The generated front/back/tags baseline remains separate from edited Card fields.
Refresh updates a field only when its literal stored bytes still equal that baseline; scheduler
fields and immutable events remain owned by the Card writer. A missing source/example/block or
stale recording blocks ordinary queue admission; explicitly retained saved faces remain usable.

Hosts hold `[ReviewMaterialPreparedMedia]` in their editor until the explicit command. Native
`enrollBuiltInNotebookSense`, atomic `enrollBuiltInNotebookSenses(_:inputs:media:actions:)`,
`addBuiltInNotebookExercise`, `prepareNotebookExercise` and `saveRetainedBuiltInNotebookMaterial`
accept those bytes. Every selected batch group supplies its own frozen action, and one failure
rolls back the complete batch. The media store verifies digest, bounded type/size and PNG decoding
or audio signatures. Source image reuse additionally requires the same workspace's corpus map.
A cancelled/failed save creates no review-media rows or files. Native reads borrow the existing
exact saved-context transaction and call `media(assetID:workspaceID:)`; a source URL or arbitrary
filesystem path never enters rendering. Saved review resources remain retained with workspace
ownership, including hidden generated media and histories; workspace deletion removes them.

## Review wire version 2

Rich recipes and their resources require the existing held review lane's **version 2** contract.
A pending resource is sent first as one bounded `media` item (`reference` plus base64 `data`), with
no dependent Card operations in that request. The response must use version 2 and provide exactly
the sent digest set in `acknowledgedMedia`. The same transaction stores that ACK and the review
cursor. Later recipe/Card requests retain version 2 and their ordinary exact operation ACKs.
Plain existing workspaces may still request version 1; an updated server may answer version 2
when delivering rich material. A version 2 request can never accept a version 1 response.

Incoming version 2 responses may include bounded `media` before `exercise` changes. The engine
validates and registers those workspace-owned bytes with the recipe/Card/ACK/cursor transaction.
Each reference is at most 4 MiB; a recipe holds at most 16 MiB, requests at most 7 MiB encoded,
and the transport retains its 8 MiB response limit. Images use PNG dimensions; audio uses only
`audio/wav` or `audio/mpeg`. No credentials, local path, Anki receipt, endpoint or voice credential
is serialized. Unsupported protocol/format, absent media ACKs or missing owned bytes fail and
leave requests pending; an old server cannot silently discard recipe/audio and report sync success.

The independent backend/mobile repository must explicitly adopt this contract and the schema-39
shared snapshot before real rich-material synchronization is available. Local cross-database
codec/apply tests are evidence for this boundary, not a deployed server or physical-device pass.
No service endpoint, hosting configuration, consent rule or production deployment changes here.

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
