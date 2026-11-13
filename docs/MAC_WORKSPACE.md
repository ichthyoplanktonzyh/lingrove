# Native Mac corpus, review and progress

This is the maintained description of the native Mac integration. Completed wave plans,
dispatch notes and individual delivery reports have been consolidated here and removed from
the working tree. Their implementation and historical reports remain available in Git.

## Product organization

The existing Vocabulary window has three outer destinations: **Personal corpus**, **Review**
and **Progress**. It retains the original corpus page, including its own categories, list,
details, toolbar, editors and interactions. There are no additional outer corpus/topic groups.
The menu bar retains its existing presentation and controls. Both autocomplete and language
learning remain core capabilities; closing the corpus window does not stop the menu-bar app.

The current presentation work follows [MAC_UI_SYSTEM.md](MAC_UI_SYSTEM.md): adapt account,
sync, review and Progress to Lingrove's native appearance and navigation. Earlier extraction
choices to preserve Nibomo's visual design are provenance, not a requirement to keep forced
dark appearance. The original corpus page and menu bar remain the visual/interaction baseline.

The footer opens the existing Settings window; the account action selects its existing Account
page. It observes the app-owned account/sync state rather than constructing another service.
Saving corpus material never enrolls it for review. A sense is explicitly enrolled; examples provide
material. Local corpus, review and statistics work without an account. Anki remains optional
and its history/scheduling are separate from built-in review.

Review now contains equal-level Lingrove / Anki choices. Lingrove provides Due now and Review
content; ordinary navigation shows the overview without starting a round. Corpus details show
each target's state/actions, and multi-selection provides explicit built-in enrollment or Anki
preparation. Settings and Home use the same target distinction. User-facing text is limited to
actions, status and necessary errors/confirmations; developer ownership explanations stay here.

## Ownership and data flow

| Owner | Responsibility and collaborators |
| --- | --- |
| LingroveAppEnvironment / MacNotebookAppServices | Construct one app-lifetime repository, corpus store, account, sync, speech and review facade. Inject Progress from that same repository. |
| VocabularyWindowController | Own the reusable window, three-way navigation, pending source links and visible-page lifecycle. Footer callbacks reuse SettingsCoordinator. |
| NotebookWorkspaceHostController | Retain the original corpus hosting controller across navigation. Mount one destination; scope its appearance and native toolbar to that destination. |
| BuiltInReviewController / Session / IO | Reuse Nibomo presentation with one frozen-scope session, writer and exact-window keyboard monitor. Source callbacks return to the selected corpus sense. |
| NotebookProgressView / Model / IO | Own destination-lifetime subscriptions and cancellable analytical reads. Hide/re-enter revokes stale publication and reloads the current scope. |
| LingroveNotebookEngine / DatabaseCore | Own SQLite correctness, account/workspace/notebook fences, atomic corpus/review commands and immutable read results. Cloud runners use narrow storage adapters. |

The corpus page source stays under UI/Vocabulary. The outer sidebar is UI/NotebookWorkspace;
Progress is UI/NotebookProgress. Services/Presentation owns native hosting. Query/aggregation
values live in the shared engine, independent of AppKit or SwiftUI. SOURCE_LAYOUT.md records
the physical placement; package READMEs describe the shared storage and cloud interfaces.

### Note and review material ownership

The current built-in enrollment path uses a shared Note and default Note Type; source fields,
custom fields and card templates are defined in [REVIEW_TEMPLATE_DESIGN.md](REVIEW_TEMPLATE_DESIGN.md).
The shared notebook package owns the values, projections and template renderer; the engine owns
transactional persistence, generated cards and retained history. The native review session borrows
those boundaries and owns window-lifetime editing and practice. Explicit Anki sending uses the same
Note through [ANKI_NOTE_SYNC.md](ANKI_NOTE_SYNC.md), with its own connection and receipts.

Legacy material recipes and their editor remain in the source for existing exercise and association
paths; their presence does not describe the default Note enrollment journey. Existing data is not
automatically converted. Save, cancellation and enrollment preserve their separate meanings.
Review v3 and its deployment boundary are documented in [NOTEBOOK_SYNC_CONTRACT.md](NOTEBOOK_SYNC_CONTRACT.md).

### Window and review lifecycle

Normal navigation keeps corpus filters, selection and editor ownership. A sheet or unsaved
review draft blocks conflicting navigation/Close; explicit source links wait until it ends.
Returning through an entry/sense deep link reveals the actual source through previous filters.

Hidden destinations stop their reading/search/speech or statistical work. Review retains its
practice state but revalidates scope when resumed. Number/Space/Enter/Undo handling requires
the exact key window, visible review route, appropriate phase, no editable responder or sheet,
and an idle writer. Tab retains its original purpose.

Search's actor retains retrieval-only preparation state. Each saved revision compares bounded
source fields and confirmed associations/cues; normalization and fingerprints are rebuilt only
for affected sense/meaning records. A completed embedding-reconcile token allows display/tag/
classification edits to reuse vectors. Keyword/hybrid ranking, thresholds and retrieval text
budgets remain shared with the complete policy build.
Consecutive single-entry receipts with unchanged semantics take a narrower preparation path:
the store pairs original/new UI revisions, and the search actor reuses semantic material and
meaning destinations while replacing only the changed entry's document slots. Missing or
debounced gaps, insert/delete/merge and changed semantics use complete comparison. This keeps
the fast path dependent on an admitted transaction receipt, not an inferred timestamp.

The separate `sense-vectors-v2.sqlite` cache stores exact little-endian Float32 rows by text
fingerprint, tagged with model identity/dimension. A change commits inserted/retired rows in
one transaction. Cached inputs contain hashes and normalized vectors, never source text.
The normal cap is 49,152 vectors and 256 MiB of database pages; SQLite's transient WAL may add
another bounded transaction. Larger collections retain a deterministic subset and rebuild
uncached vectors as needed. Invalid rows are discarded, an unreadable derived file can be
recreated, and failed persistence remains pending for the next reconcile. Corpus storage is
independent. The previous JSON cache is ignored; there is no canonical schema migration.

Graph projection is a window-owned actor operation keyed by saved revision, filters, query,
expansion and display language. Selection, hover, drawer width, camera and appearance reuse the
same projection. Changed inputs are recomputed off MainActor; equal visible geometry retains
canvas identity, accessibility nodes and camera. Real topology/query changes still perform a
complete projection. Grouped classification reads and request-local count memoization remove
repeated whole-directory scans while preserving unique membership across DAG paths. MainActor
drawing reuses adjacency and rejects offscreen edge paths before invoking AppKit. There is no
per-frame rebuild of the semantic graph, and hiding the destination cancels its projection task.

The sidebar's native List may write its selection binding during a SwiftUI view update.
NotebookWorkspaceNavigation queues the latest request in a later MainActor job before invoking
VocabularyWindowController: pausing review and swapping hosted pages must not publish state or
replace native views inside that binding write. A sheet, window Close or explicit source opening
revokes the queued selection; the controller rechecks window/sheet eligibility when it executes.
SettingsNavigationModel likewise defers sidebar requests; explicit search/link routing stays
synchronous and window Close revokes pending input. These boundaries avoid publishing changes
while SwiftUI is updating its selection binding.

The corpus toolbar is detached outside the corpus destination and restored only with its
own retained host. Its Edit/Delete actions must never remain over Review or Progress.
All destinations inherit the owning native appearance; the corpus keeps its original page.
Account navigation cannot publish a forced color-scheme preference to the Settings window.

An accepted writer remains owned through ordinary window Close. Explicit Quit drains CLI,
corpus and review writes before retiring sync/repository. System termination retains its
separate immediate runtime cleanup; it does not promise an asynchronous app Quit drain.

### Personal statistics

Progress uses real effective events for the current workspace and notebook. Historical
exercise/enrollment associations retain ratings through merge, pause, withdrawal, missing
sources and Card deletion. SQL EXISTS prevents duplicate ownership from multiplying events.
Undone ratings are excluded consistently from totals, daily series, distributions and streaks.
Anki, ordinary non-notebook Cards and other scopes are excluded.

All effective history determines totals and current/longest streak; the 140-day display range
only bounds the chart. Event dates use their recorded timezone with a frozen fallback. Civil
date/DST helpers and schedule boundaries reuse Nibomo rules. Forecast includes only currently
eligible built-in exercises and uses the original eight half-open schedule buckets. Sense and
exercise counts remain separate. There is no invented freeze reward or community dependency.

NotebookProgressIO opens a short-lived SQLITE_OPEN_READONLY engine connection to the same
physical file. This path validates the existing schema and skips bootstrap, WAL-mode changes
and expiry maintenance. Ordinary initializers preserve their normal behavior. Native readonly
does not promise an immutable filesystem: SQLite WAL sidecars can have separate requirements.

The actor performs aggregation off MainActor. The model checks workspace/notebook/generation and
the durable Progress dependency token before publishing. Organization-only document revisions
do not invalidate statistics; rating, undo, participation and schedule changes do. While visible, a
two-second metadata probe detects unannounced external writes; unchanged tokens do not trigger
decoding or aggregation. Relevant notifications, activation and date/timezone changes also refresh.
Hidden pages cancel subscriptions/reads and clear content. Empty history and load failure have
distinct UI; failure is never presented as a successful zero count.

### Corpus save and sync

Capture, editing, CLI, sync and review use one durable corpus. Ordinary entry saves prepare
the target subtree, reuse writer-owned validated projections and commit through the common
CAS/journal/media/source-refresh transaction. Connection caches are derived values guarded
by scope/revision/generation and a durable corpus dependency clock; they are not write authority.
Structural/import/restore/remote operations retain their complete validation paths.

`NotebookChangeTracking` installs additive SQLite metadata and triggers on writable connections.
Each transaction advances only its affected domains: corpus, review, Progress, ownership and
synchronization. The counters follow raw SQL and foreign-key cascades across connections and
roll back with the business rows. No-op UPDATEs, undo's pending-only ACK and media-cache access
timestamps do not invalidate presentation. Schema changes and a random clock epoch prevent
stale cache reuse after metadata replacement. A read-only/incomplete installation uses the
conservative SQLite external/local counters until a writable host repairs tracking.

`MacNotebookRepository` publishes sequence and domain flags together after probing committed
metadata. Owner changes or probe failures invalidate every destination. Corpus observes corpus;
Review observes corpus/review; Progress compares its own fence. Sync coalesces domain flags and
rebuilds ownership proposals only when account decisions or relevant corpus snapshots change.
Ordinary editor receipts are applied before publishing, and corpus enrollment invalidates its
participation reader once. Counters are currently database-wide within each domain, so changes
in retained workspaces may conservatively refresh the active workspace too.

Semantic and classification editors submit record-level `VocabularyOrganizationEdit` values.
Their transaction reuses checked lexical state, merges against current records and validates
the changed graph/directory. SQL and pending journals contain the actual organization delta,
and those edits do not refresh card faces. No-op retries keep the saved revision.
CLI add/append planning operates on canonical headers, and sense updates reconcile only
their affected evidence citations. Full batch validation and atomic receipts remain required.

Account authentication does not adopt or upload local content. Workspace selection, ownership,
explicit local acceptance and sync opt-in remain separate operations. Corpus/media/review lanes
have independent status and retry behavior. Network waits do not hold SQLite transactions;
late account callbacks and commands retain their original generation. Unsaved translations,
autocomplete context and screen content do not enter corpus sync.

`MacNotebookIO` runs workspace connection, ownership calculation/decisions and periodic
scheduler work on its serial executor. Ownership actions publish their committed state
asynchronously. The controller rechecks account/task/version identities after each await.
Periodic sync probes unresolved first-connection metadata before decoding any retained
recovery document. App termination drains admitted notebook IO before closing storage.

The account overview offers **Sign in or create an account** even when this app build has no
service configured. Email and eight-digit code are the supported authentication path; no password
or social-provider controls are implied. Back, Close, resend, expiry and errors borrow the shared
AccountSession state machine. A missing/invalid service has an actionable explanation leading to
secondary Account service settings, and cannot send a request. Normal login displays custom
service provenance by host; full URLs and switch/reset consent belong to that secondary page.

Only the Mac composition root reads the optional paired Info.plist build defaults. The checked-in
defaults remain empty while deployment is deferred. A saved custom pair wins over build defaults;
any saved pair stays pinned across later releases until an explicit switch. Returning to the app
default signs out with the same Keychain/generation fence. Removal stays disconnected on relaunch,
and logout's restore=false gate applies equally to default and custom services. URL drafts retain
their window lifetime and block authentication/sync until saved or reverted.

## UI provenance and supported surface

- [Review and account component sources](MAC_REVIEW_ACCOUNT_UI_REUSE.md).
- [Personal Progress component sources](MAC_PROGRESS_UI_REUSE.md).
- The app bundles Resources/NibomoUI-LICENSE.txt. Upstream source attribution is retained; the original mobile tree now lives in the private mobile repository.

Review uses extracted native controls and queue surfaces alongside the Note editor and renderer. Progress uses the
original streak/calendar, paged stacked-rating chart and selectable schedule donut/legend.
Necessary adapters use AppKit, the shared sense model and local image bytes. Community,
leaderboards, provider-management UI, rewards, premium and telemetry are outside this surface.
Full UIKit/MarkdownUI/RaTeX math/table rendering parity is not implemented.

## Validation and practical limits

Use synthetic state and private validation hosts as described in [MAC_UI_SYSTEM.md](MAC_UI_SYSTEM.md)
and AGENTS.md. The installed Dev app contains real user data and is not a test fixture.

The Note/template and Anki protocol fixture checks and their limits are recorded in
[REVIEW_TEMPLATE_DESIGN.md](REVIEW_TEMPLATE_DESIGN.md) and [ANKI_NOTE_SYNC.md](ANKI_NOTE_SYNC.md).
Local tests do not establish live Anki, production service deployment, physical-device sync,
VoiceOver, all locales or final compositor-based visual acceptance. Review v3 requires compatible
backend adoption. Verify the affected journey and record any remaining gap for each change.
Historical checkpoint details and individual execution results are available in Git history.

## Corpus performance checkpoint (2026-11-10)

The user authorized a baseline using the real Dev corpus and a consistent backup. The fixed
input contains 9,671 entries, 14,476 senses, 28,891 sources, 13,085 meaning nodes and 338 categories.
The live measurement was contaminated by concurrent CLI writes; it is diagnostic evidence,
not the stable before/after reference. A Release private host then loaded a copy of that exact
backup without CLI, synchronization or model downloads. It uses the production corpus window
at 1240 × 760, initially by entry/list/compact, with keyword search and the built-in review section.

The unmodified baseline is source `9f319882ff95f871e409525473add54da7e7f47a`. A 20ms main-runloop
timer measured gaps during computer-use actions; these are main-thread unavailability, not
input-to-frame latency. Accessibility traversal itself is included in the action windows.
The same computer-use method is required for a fair comparison. Single-pass observations:
entry selection 4.14–4.25s maximum gap; disclosure 4.10–4.14s; list scroll 0.49–0.52s;
language filter 4.17s; clearing search 6.48–6.73s; switching to meanings 4.40s; switching
back to entries 10.63s. Ten seconds of idle observation had no gaps >=100ms. Ordinary search
was visually pending after its first tool round trip and later showed eight results; those
observations are not an exact search latency measurement. Graph, close/reopen and edit/save
were not covered by this first baseline. The first archive load took 78.89s and window
construction/layout took 7.04s in the opt-in host; neither includes all startup costs.

The snapshot, source/binary hashes, detailed operations, raw ticks and test results are retained
locally in `build/corpus-performance/`. No corpus text or database is committed. The canonical
backup is under the user's explicitly authorized Dev Backups directory and is never opened
by the test repository: each run creates and drains a disposable copy.

The optimization keeps ordinary browser sorting in creation order so editing a note does not
move its row. New-entry saves retain the current query, language, tag and organization and
show an explicit “Show in vocabulary” action for clearing those constraints. Search results
remain visible during replacement; complete admitted matches are paged for presentation,
and filtered export uses the same deduplicated selection only after the current corpus
revision/query finishes. Search relevance thresholds and embedding input content are unchanged.

The narrow participation query keeps historical merged-sense enrollment grouping, deleted-card
exclusion, disabled-template handling, scheduling validation and generation/revision fences.
Its IO owner performs the read away from MainActor; corpus browsing creates no enrollment.
The original full review queue and its writers retain their existing boundaries.

### Verified optimization result

The final fixed-input Release run completed its handoff successfully. Its initial store load
was **4.816s** (baseline 78.892s), and window construction/layout was **1.327s** (baseline
7.044s). These are instrumented operation durations. The startup improvement includes indexing
semantic child rows by owner in `VocabularySemanticDatabaseProjection`, while retaining ordering,
round-trip/orphan validation and the unchanged on-disk format.

The following values are maximum main-runloop gaps within recorded computer-use action windows,
not exact input-to-frame latency. Each is a small number of observations with the same fixed
corpus and UI host; AX traversal contributes to the gaps. Selection and scrolling combine two
operations in the final run, so compare their maxima rather than inferring a percentile.

| Operation | Before max gap | Final max gap |
| --- | ---: | ---: |
| Entry selection | 4.250s | 0.527s |
| Expand / collapse senses | 4.097 / 4.142s | 0.465 / 0.520s |
| List scroll down/up | 0.494 / 0.516s | 0.525s combined |
| English language filter | 4.173s | 0.537s |
| Clear search | 6.484–6.731s | 0.852s |
| Switch to meanings | 4.395s | 1.129s |
| Return to entries | 10.627s | 1.070s |

Scrolling did not show a meaningful measured improvement. Category selection/detail-scroll
measurements used different populated categories and cannot establish a speedup. Exact/common/
missing searches were verified against visible results; the common query now returns all 11
admitted senses rather than truncating to eight. Original search completion times were only
bounded observations, so no precise search-latency percentage is claimed.

Functional checks in the final real-data copy confirmed row selection, disclosure with retained
reading destination, list and category-detail scrolling, language-filter restoration, and search
clear. A note was saved and reopened; a subsequent unsaved marker was cancelled and absent on
reopen. No original corpus was edited by these tests. Menu-based reopen after closing the last
private-host window could not be verified (CUA/AX timed out); this remains distinct from a product
failure. The earlier `fixed-after` handoff exceeded its limit and failed as an automation run;
its data was not substituted for the successful `final-check` run.

Focused shared checks passed: 15 identity/document tests, 8 review integration tests and 12 codec/
SQLite tests. Native search, classification, creation, merge and app-service suites passed.
A flattened-list optional-tag regression was corrected; the mouse and selection-retention tests
then passed together after unlocking the Mac. The final private-host measurement test passed.
The existing AppKit geometry warnings remain in native logs; the checked visible flows rendered
and remained usable. Semantic-model-backed search and graph panning were not performance-qualified
in this keyword-only checkpoint.

Final per-operation timing windows are preserved in `final-check/operations-ui.jsonl`, with
raw timer samples in `main-loop-ticks.json` and the paired maxima in `comparison-root.json`.
The final run's whole-observation maximum was 1.455s, versus 10.627s before. This statistic
covers different observation lengths and extra validation actions, so the per-operation table
is the preferred comparison. The final cold-load timing supersedes the interim 69.93s result.

The optimized `Lingrove Dev` Release application was then installed in place at the existing
checkout-specific Development path, preserving its designated signing requirement. The new
executable hash and running process were verified. The user explicitly requested application-only
updating and declined the proposed per-table comparison; the installer did not open or replace
the live database. The earlier consistent corpus backup and the previous application bundle
remain available locally. The isolated-host menu-reopen limitation remains unverified.

## Organization write checkpoint (2026-11-11)

The organization writer was compared with source `59e63bf8` using independent copies of
one synthetic database. It contains 10,000 entries, 20,000 senses, 40,000 sources, 14,000
meaning nodes, 350 categories, 14,000 category memberships and 12 enrolled review senses.
Both versions used Release builds, the same input and operation order, and three samples.

| Local operation | Before median | Current median |
| --- | ---: | ---: |
| Edit and save one meaning definition | 24,954.3 ms | 439.5 ms |
| Edit and save one category definition | 29,613.4 ms | 144.8 ms |
| Plan 50 ordinary sense updates and validate the batch | 11,366.7 ms | 634.5 ms |

The first two measurements include local storage work. The batch measurement covers planning
and final relationship validation. CLI transport, final batch SQL and UI rendering require
separate measurements. Logs remain under `build/mac-w2-c/organization-release-benchmark.log`.

Validation passed 80 native tests, 38 shared rule/codec/wire tests and 47 storage integration
tests. Organization-specific tests protect unrelated lexical/review rows with SQLite triggers,
verify independent and conflicting edits, reject invalid combined relationships, roll back
late journal failures, preserve public-intent rules and reopen the saved document.
The installed Dev application and its live corpus were outside this synthetic checkpoint.

## Domain invalidation checkpoint (2026-11-11)

Compared with `070f0e46`, writable engine connections now retain checked corpus state across
ratings and transport-only commits. SQLite dependency clocks replace whole-database change
counters on the ordinary tracked path. Progress uses its own counter and owner fence; the
repository publishes domain flags with each sequence. Ordinary editor receipts publish after
application, and corpus enrollment triggers one participation invalidation. Equal Note/type
sync echoes skip writes using literal, sorted JSON comparison. Media ACKs and material
confirmations are transport metadata rather than review presentation changes.

One synthetic seed was copied independently for each version and sample: 10,000 entries,
20,000 senses, 40,000 sources, 14,000 meaning nodes/mappings, 350 categories, 14,000 category
memberships and 12 enrolled senses. Both versions ran in Release with identical operation
order, a warm corpus read before the first rating and three samples. Medians:

| Local storage operation | Before | Current |
| --- | ---: | ---: |
| Read corpus after a rating | 4,455.1 ms | 0.33 ms |
| Save one entry after a rating | 5,007.3 ms | 452.6 ms |
| Read corpus after another connection retires upload journals | 4,424.3 ms | 0.56 ms |

The first and third operations now reuse the trusted in-memory corpus instead of decoding
it again. The second includes its actual entry transaction and card refresh. Rating execution,
initial load, one-time trigger installation and UI rendering are outside these timed windows.
Logs and raw samples remain in `build/mac-w2-c/change-domains-release-benchmark.log`.

All 92 engine tests passed. Native coverage passed 30 tests across repository receipts,
Review, Progress and account/sync, followed by a final 15-test Progress/account regression
after the last changes. Strict lint passed. Checks cover external commits, raw corruption,
rollback, pinned readers, account ABA, additive installation/read-only fallback, incomplete
trigger coverage, pure review/media ACKs and exact UI read/invalidation counts. The initial
full-suite failure compared the new synchronization counter as if it were a business row;
that assertion now permits the expected journal-retirement clock while still checking the
clock's rollback. The benchmark fixture was corrected to send the required Note question
version; no product admission rule was relaxed. All final runs passed.

Installed Dev binaries and live data were unchanged. Domain clocks remain database-wide,
so another retained workspace can conservatively invalidate the same domain. Search-index
and graph-projection rebuild scope remain the next independent performance stage.

## Search and graph checkpoint (2026-11-11)

This completes the final primary code stage of the current large-library refactor. The existing
app/repository/window ownership remains in place. Search preparation and graph computation are
derived reads with explicit lifetime/cancellation; the new vector database is disposable storage.
Dev installation and real-library experience acceptance remain separate integration operations.

A Release harness compared `217d1fa4` with this change using fixed content/primary IDs and three
samples per version: 10,000 entries, 20,000 senses, 40,000 contextual source examples, 14,000
meaning nodes, 14,011 confirmed mappings, 350 categories and 14,000 category memberships.
Fifty root categories own 300 children. The displayed taxonomy has 14,351 nodes in both versions.
Medians measure local preparation/projection, not input-to-frame or model-inference latency:

| Operation | Before | Current |
| --- | ---: | ---: |
| Prepare search after one sense definition edit | 100.5 ms | 1.3 ms |
| Prepare search after a shared meaning definition edit | 289.5 ms | 104.3 ms |
| Build the taxonomy graph projection | 545.9 ms | 128.4 ms |
| Repeat the same graph request | 534.5 ms | 0.018 ms |

The single-sense update rebuilds 1 sense and 0 meaning retrieval documents; the old entry cache
rebuilt its 2 senses plus all 14,000 meaning documents. The shared-meaning update rebuilds its
12 associated senses and 1 meaning, versus 20,000/14,000. Semantic changes and missing/gapped
entry receipts still perform a linear comparison of small inputs. Actual topology/query changes
still construct a complete graph on its worker; camera/selection/appearance reuse the snapshot.
The final search harness retains the previous snapshot to account for copy-on-write publication
and uses the exact preparation method from `217d1fa4`. It supersedes an initial full-build search
baseline, which overstated ordinary-entry improvement. Corrected raw search samples and sources
are preserved in `build/mac-w2-c/search-preparation-final*`; graph/cache measurements are unchanged.

The cache test uses 34,000 synthetic 1,024-dimensional unit vectors, without a GGUF. Updating
one fingerprint previously spent a median 10,381.6 ms encoding 280,874,033 JSON bytes and then
skipped persistence at the 64 MiB limit. Current storage spends 20.4 ms inserting/retiring 2 rows,
successfully restores all 34,000 vectors and occupies about 159.6 MB on disk. This comparison is
an update attempt versus successful persistence, not two successful saves. It qualifies cache
storage and capacity, not embedding quality or generation throughput. Raw samples and copied
harness sources are under `build/mac-w2-c/search-graph-*`.

Validation passed the shared taxonomy test and all 93 engine tests, including exact empty/NUL
BLOB binding. The initial native run passed 44 tests with 3 optional tests skipped; its unchanged
canvas code passed expansion, drag, camera and cooling checks, and the entry graph screenshot
was inspected. A subsequent search/cache run passed 14 with 3 optional model tests skipped.
The final combination passed 34 tests, including review, Progress, account/sync, account-scoped
cache removal and retry after cache persistence failure. Strict lint passed. Actual GGUF
multilingual/relevance suites remained opt-in and were not executed; retrieval text, ranking,
model identity and admission thresholds were unchanged.

The initially locked native combination failed 3 desktop-dependent animation tests (6 assertions):
`quickNativeDragReachesWorkerBeforeCooling`, `searchNavigationStopsInitialFitWhileLayoutIsSettling`
and `nativeCanvasCoolsAndStopsWhenRemoved`. Two native session probes confirmed
`CGSSessionScreenIsLocked=Yes`; AppKit's occlusion gate correctly stopped frames. The taxonomy
test verified projection/accessibility identity, but its screenshot was blank in that locked
session. No product visibility gate was relaxed. After the user unlocked the desktop, a focused
run passed all 25 executed tests (3 optional tests skipped): graph UI, search preparation/search
and repository integration. All 6 graph UI tests passed, including the 3 previously limited
animation tests. The visible taxonomy screenshot was then inspected: axes, category, meaning,
five sense branches, labels and controls rendered normally. New tests also verified consecutive
entry receipts and complete fallback after debounced gaps. No desktop validation item remains
open in this checkpoint. Large-graph pan/draw FPS and actual GGUF inference throughput were not
performance-qualified. No installed Dev bundle or live corpus was opened, copied or changed.

## Synthetic operation inventory (2026-11-11)

The subsequent performance audit calls real production commands and projections through an
isolated Release/arm64 test host, without windows or input synthesis. Product source remains
`093608d4`; this checkpoint adds test fixtures, measurement/report tools and documentation only.
The installed Dev corpus and bundle were not accessed or replaced.

The [complete report](benchmarks/corpus-operations-2026-11-11.md) covers 83 timing windows at
100, 10,000 and 20,000 initial entries. Thirty-five frequent windows have five independent
samples per size; the remaining windows have single observations. The larger seeds have
20,000/40,000 senses, 40,000/80,000 examples, 14,000/28,000 meaning nodes, 2,000/4,000 enrolled
senses and 1,000 rating records. Raw samples, CSV and JSON statistics accompany the report.

At 10,000/20,000 entries, median capture is about 0.47–0.52s / 0.95–1.07s. Early-position,
associated sense removal is about 2.44s / 4.63s, versus 0.38s / 0.79s for the tail-position,
unassociated case. Both position and association differ; this is not a controlled estimate
of association cost. The transaction dominates capture/removal, while the UI read-index delta
is measured in milliseconds. Some complete-document save paths take single observations of
40–50s / 124–148s with the dense review fixtures. Repeated whole-source resolution during
all-Note material refresh and large position/journal updates are identified follow-up areas;
their exact component shares were not separately profiled. Initial corpus load and post-full-save
cache recovery remain visible costs. Actual input-to-frame latency, inference and networking
were outside the timed windows.

Both small preflights and all 525 frequent-window samples actually executed and passed their
measurement checks. The original full scan completed the first two sizes, then failed its
20,000-entry CLI retry assertion because it reused a 30-second envelope after a 97-second save.
The test now refreshes only request ID/expiry while retaining the durable idempotency key.
The corrected 20,000-entry CLI/Review/Progress/export/backup/stage tail actually executed and
passed on a fresh generated seed. Product source hashes match between runs. This is a composed
checkpoint, not an uninterrupted passing full scan; the original failure is retained. The
782 raw timing records include one explicitly excluded expired-envelope rejection, and the
independent tail's different preconditions/counts are marked in the report and data files.

An unresolved product issue is separate from timing success: deleting a Note-based enrolled
sense rejects with `ReviewTemplateError.sourceUnavailable` in all 18 formal attempts. The
test verified that the rejected target and notebook revision remain unchanged. It must not be
reported as successful deletion performance or feature acceptance. Source reconciliation before
missing-source handling is documented for the next correctness fix. No product fix was applied
in this measurement-only checkpoint.

The private hosts, generated databases, copied dependency cache and repository-scoped
`build/DerivedData` were removed; their absence was checked after the final passing tail.

## Local data-layer mutation boundary (2026-11-11)

The follow-up changes the local mutation boundary rather than replacing SQLite, the domain
model or the app-owned repository. A checked save plan now carries the actual row delta,
affected entry/review-source IDs and a version-fenced presentation receipt through the same
atomic transaction. Full saves retain their checked state/projection after commit; rollback
revokes it, and external SQL/account/generation changes still invalidate it.

Single-entry validation reuses reverse ownership indexes. Capture, ordinary editor changes,
sense creation/move/merge, entry deletion and one-row manual import use the restricted entry
path. Complete batches, restore and merge undo retain full preparation. Full-save row diffs
separate changed payloads from dense position compaction; the position update uses SQLite's
joined update while preserving the existing journal and wire ordering format.

Review refresh selects affected Notes/memberships and reuses one joined source index. Removing
an enrolled Note source marks retained material unavailable without deleting Card scheduling
or append-only review history; restoring the source makes it renderable again. Focused
SQLite integration tests cover deletion/restore/reopen, retained history, unrelated-material
write protection, rollback and indexed validation authority. The previous checkpoint's
`sourceUnavailable` deletion rejection is fixed by this material-admission behavior.

The archive forwards an optional receipt between exact notebook versions. `VocabularyStore`
patches affected entries or retains its index for organization-only changes. A missing receipt,
a revision gap still uses the complete read worker. Neither cache
nor receipt is accepted as write authority. `SOURCE_LAYOUT.md` records type ownership and flow.
Batch index patches retire old owners together before installing replacements, protecting
headword-key exchanges and historical aliases moved between owners. A focused native test
checks that atomic projection behavior independently of persistence timings.

## Unordered corpus membership (2026-11-11)

The user clarified that senses and independent examples have no business ordinal. Corpus
membership and semantic/directory relationships are now compared by identity; authored
paragraphs/images, original text/ranges, explanation history and template structures keep
their sequence. The accepted trade-off is in [ADR 0004](adr/0004-unordered-corpus-membership.md).

The row codec ignores old membership positions without rewriting existing payloads on open,
and new membership rows store zero. Deletions therefore do not compact or journal survivors.
Wire envelopes retain rank for compatibility, preserve confirmed values on upload and ignore
rank-only differences for membership; add/reset fences still protect intentional removals.
Display/default selection uses stable creation-time/identity rules, while saved review plans
and Notes retain explicit example IDs. Literal editor merging ignores permutations while
retaining authored Unicode bytes and body order.

Entry reconciliation uses a connection-owned reverse semantic index and a restricted change
proof. Only dependent patterns/mappings and evidence retractions are projected; full imports,
restores and arbitrary graph changes retain complete validation. Arrays still incur linear
copy/compaction costs; neither the new model nor this checkpoint promises constant total latency.

The targeted comparison uses the same closed 10,000-entry seed (20,000 senses, 40,000 examples,
14,000 meaning nodes, 2,000 enrolled senses and 1,000 rating records) for three alternating trials
of checkpoint `4c73ddd3` and this change, in Release. Median engine milliseconds are:

| Operation | Before | After |
|---|---:|---:|
| Entry note save | 205.953 | 208.928 |
| Front sense removal | 1491.587 | 169.007 |
| Tail sense removal | 185.982 | 173.974 |
| Enrolled sense removal | 1525.295 | 175.515 |

This is a focused comparison, not a repeat of the 83-window inventory or measured UI/frame
latency. Connection initialization and first notebook load are outside the windows. The
[raw samples and seed hash](benchmarks/corpus-membership-2026-11-11.focused.json) preserve all
trials; every input copy passed SHA-256 equality and every trial retained all 1,000 ratings.
The ordinary save is effectively unchanged in this small sample. Position and association
are not independently controlled by the two removal cases; their component shares were not
profiled separately. Core checks actually passed 117 shared tests (three opt-in real-server interop bridges were
skipped), plus 101 engine Swift Testing and
40 engine XCTest checks. Trigger-protected tests reject survivor rewrites, and permutation-only
saves retain the current revision.

Final isolated native Release validation actually executed 27 passing checks,
zero failures and 1 intentionally disabled visible-UI journey. This includes
identity-based browser behavior, literal editor permutations/Unicode/body order, repository
save/reopen and account-generation fencing. Strict SwiftLint and diff checks passed. The
private hosts, synthetic trial databases, copied package source and repository DerivedData
were removed and their absence verified. The installed Dev application/data were not accessed
or replaced. Final native evidence is under
`build/corpus-operation-benchmark/unordered-membership-native-final/`; focused engine evidence
is under `build/corpus-data-layer-paired/unordered-membership-10000/`. No complete operation
inventory or actual frame/input latency is claimed by this checkpoint.

## Remaining corpus paths (2026-11-11)

The next slice keeps the same SQLite/domain boundaries and removes repeated preparation at
those boundaries. A connection's checked state now retains canonical evidence offsets and image
references. Narrow entry saves reuse those indexes; the row projection uses an immutable base
plus a bounded overlay, so a transaction does not copy every row dictionary for one note.
Scalar equality still checks literal text/numeric representations, with full encoding retained
for structured history/layout leaves. Retained projection versions survive overlay compaction.

Organization commands seal changed root IDs after applying their record expectations. Semantic
validation rechecks those roots and their dependent mappings, relations and cue targets, while
untouched identities remain reserved. Hierarchy additions still traverse the complete hierarchy;
directory edits retain full classification validation. Only changed ownership groups are encoded
and compared for public intent. There is no caller-provided unchecked dirty-ID save interface.

Global tag removal is an annotation-only domain command: canonical evidence, semantic links,
media and review history retain their prior proof. Batch manual import builds its headword lookup
once, including newly created owners, rather than repeatedly normalizing every saved expression.
Generic imports, restores and merge undo keep complete validation, but share joined values and
the resulting checked state with persistence. Actual row roots scope public-intent comparison;
private receipts and timestamp-only bookkeeping still use the existing public encoder's rules.

Cold SQL reads establish one reusable full validation result. The archive can pass its exact
version/token's joined entries to the read worker instead of joining them again. First search
preparation memoizes repeated normalization within that pass, and keyword ranking shares phrase
decisions within one query while retaining NaturalLanguage word boundaries. A bounded example
retrieval regression test ensures that an annotation save does not change embedding material
merely because a membership lookup iterates differently. Meaning browsing skips search-only
material for empty queries; taxonomy groups reuse the already sorted meaning sequence.

The focused remaining-path harness calls production commands/models without opening windows or
synthesizing input. It measures 43 windows, three trials each, at 10,000 entries / 20,000 senses /
40,000 examples, with 14,000 meaning nodes, 688 categories, 14,000 memberships, 2,000 enrolled
senses and 1,000 rating records. Baseline product `65da47da` and the candidate use separately
generated equivalent synthetic seeds, the identical timing harness and operation order,
Release/arm64 on MacBookPro18,2. These are command/projection durations, not frame/input latency,
OS-cache-cold disk measurements, or an 83-window inventory rerun. Three samples do not establish
a percentile or a latency guarantee.

Median milliseconds from the passing three-trial runs:

| Remaining operation | Before | After |
|---|---:|---:|
| Entry note save, store command | 308.120 | 126.440 |
| Favorite capture, engine transaction | 206.104 | 57.980 |
| Sense removal, engine transaction | 164.259 | 38.737 |
| Shared meaning edit | 332.327 | 82.606 |
| Category edit | 190.192 | 60.135 |
| Global tag removal | 16152.228 | 610.104 |
| Manual batch import, 50 new entries | 16788.124 | 3754.415 |
| Manual batch re-import, 50 new senses | 16686.302 | 3799.452 |
| Sense merge undo | 15629.639 | 3649.646 |
| Full backup restore | 17192.996 | 4904.003 |
| Keyword search | 112.628 | 54.408 |
| First library load | 4210.592 | 4030.341 |
| First search preparation | 268.012 | 259.838 |
| First taxonomy graph preparation | 128.855 | 116.286 |

The [complete 43-window comparison and raw samples](benchmarks/corpus-remaining-2026-11-11.json)
retain medians and maxima, fixture counts and binary/source identities. The baseline archive
runner copied the same timing harness before product changes, but its source-manifest collector
returned an empty list because the archive had no own Git index. Baseline build logs, binary
hash and the archive procedure remain under `build/corpus-remaining/before/` and
`build/run_remaining_baseline.py`; there is no retrospective baseline source-hash proof. The
runner now handles index-free archives explicitly. Candidate source hashes are recorded under
`build/corpus-operation-benchmark/remaining-final/` and checked against the final product files.

The mutation improvements are large in this sample. Cold load and first search preparation
are effectively unchanged at this scale; the small graph difference is not a frame-rate claim.
First load still reads/decodes the complete corpus, checks lossless reconstruction and business
invariants, and builds its indexes. Batch/restore paths still perform complete preparation and
row projection. Removing those remaining costs requires a different read/preparation strategy;
this checkpoint does not claim they are solved or that all operations are independent of size.
Unchanged browse/CLI windows vary in both directions, so there is no universal speedup claim.

Validation passed 124 distinct shared checks (the full shared checkpoint plus the final targeted
batch-rule check), 104 engine Swift Testing checks and 40 engine XCTest checks. Three opt-in
real-server interop bridges stayed disabled. Final private native Release execution passed
56 checks; the visible-desktop journey remained intentionally skipped. It includes search
boundary/equivalence tests, bounded-example annotation stability, repository/lifecycle checks,
graph checks and batch import/cancellation. The timing envelope passed with all 129 samples.
Strict SwiftLint and diff checks passed. Final cleanup removed and verified absence of
DerivedData, copied package source, private hosts and synthetic trial databases; the installed
Dev application and real corpus were not accessed or replaced.

## Read and batch preparation at 10k and 20k (2026-11-11)

This slice measures current product `73d9180e` before another local codec change. It adds a
fresh 20,000-entry comparison alongside 10,000 entries; the older 20,000-entry inventory above
does not describe current optimized code. Each size uses the same 43 operation windows and
three trials per version, through private Release/arm64 hosts without windows or input synthesis.
Separate equivalent seeds contain 20,000/40,000 senses, 40,000/80,000 examples,
14,000/28,000 meaning nodes, 2,000/4,000 enrolled senses and 1,000 rating records.

Ten diagnostic windows run after the operation trials on another fresh seed copy. They overlap
and have one observation per size; they are not summed or described as a decomposition of one
load. The baseline 10k/20k engine loads are 3.775s/7.828s. Separately, full codec encoding and
global sorting takes 1.873s/4.139s, full row diff takes 2.828s/6.032s, and portable single-row
JSON decoding takes 1.343s/2.722s. These observations identify preparation and parser setup as
measurable work, rather than attributing every delay to SQLite IO or UI rendering.

The codec now shares one temporary row-address index across lexical, semantic and directory
reconstruction. Expected row shapes consume original offsets exactly once, retaining all old
lossless and full-domain checks while avoiding another full payload dictionary. Internal full
save diffs reuse keyed rows without globally sorting a list that SQL does not consume in that
order. Public encoding and authored child positions retain their existing deterministic order.
Domain validation, raw UTF-8 checks, workspace fences and transaction ownership stay with the
existing boundaries. No new storage format, application-data migration or service is introduced.

Median operation milliseconds, before `73d9180e` versus the shared-index/unsorted-diff slice:

| Operation | 10k before | 10k after | 20k before | 20k after |
|---|---:|---:|---:|---:|
| First library load | 4037.982 | 3968.028 | 8143.089 | 8224.940 |
| Manual import, 50 new entries | 3711.208 | 2281.353 | 8078.658 | 4707.991 |
| Re-import, 50 new senses | 3720.300 | 2277.537 | 8373.366 | 4710.296 |
| Sense merge undo | 3667.655 | 2141.588 | 7967.192 | 4531.683 |
| Full backup restore | 4896.339 | 3403.920 | 10653.622 | 6960.415 |

The [full comparison and component windows](benchmarks/corpus-read-2026-11-11.json) preserve
258 operation samples per version and twenty component observations per version. Single-entry
timings and initial library load are essentially unchanged in this slice; the improvements
are concentrated in full-save preparation. A bounded JSON-array decoding experiment added frame
scanning/buffering cost and was removed. Its intermediate run and private-process sample are
diagnostic evidence under `build/corpus-operation-benchmark/corpus-read-batch-final/` and
`build/corpus-next/private-load-sample.txt`; they are excluded from the final comparison.

The baseline archive and final native run have nonempty product source manifests and matching
timing-harness hashes, recorded under `build/corpus-next/before/` and
`build/corpus-operation-benchmark/corpus-read-final/`. Separately generated seeds have identical
counts and operation order; their bytes are not paired. Component windows are isolated CPU
work, not additive attribution of the SQL-load window or proof of a percentile.

Final validation passed 126 shared checks, 104 engine Swift Testing checks and 40 engine
XCTest checks; three real-server interop bridges stayed disabled. Private native Release
validation passed 56 checks with the visible-desktop journey intentionally skipped. The timed
envelope passed at both sizes with all 258 operation samples. Strict SwiftLint and diff checks
passed. Owned DerivedData, copied packages, private hosts, archive source and synthetic databases
were removed. The installed Dev bundle and real corpus were not accessed or replaced.

The SQL-only follow-up to `ea3505cc` requests `ORDER BY id` for each workspace-scoped family
read. The existing composite primary key can supply the sequence that reconstruction already
uses. In a separate [exact-seed 20k engine comparison](benchmarks/corpus-read-order-2026-11-11.json),
three alternating fresh-process loads per version give a median of 8278.468ms before and
7612.829ms after, about 8% lower. Paired changes are -665.639ms, -635.006ms and +53.240ms:
two trials improved and one was essentially flat, so the benefit is modest and variable.
The closed seed hash is `e324c88c52e46060cea345eed3496ad964a6f79ed108b9644c08d7b94d2d1ca7`;
every trial retained 20,000 entries, 80,000 interpretations, 28,000 meaning nodes and all
1,000 ratings. The timer excludes engine initialization and UI read-index preparation.

The 43-window native inventory above belongs to the preceding preparation slice; it was not
rerun after this single SQL ordering clause. The follow-up passed 24 targeted entry-save,
organization and change-tracking checks, including reopen, cross-connection commits, raw
corruption, rollback and generation fencing. Its package source manifest was checked against
the final tree. First load remains a full-corpus operation and a significant remaining cost.

## Bounded corpus reads (2026-11-12)

[ADR 0005](adr/0005-bounded-corpus-reads.md) separates list/detail readiness from complete
document readiness. The default list reads 100 summaries and a global SQL count, then uses
query/version-bound keyset pages. Selecting a sense reconstructs only its complete entry and
source/interpretation closure. These DTOs never populate `VocabularyStore.entries` or establish
the writer's complete checked state. A separate read-only connection prevents archive validation
from serializing later pages/details behind a full decode. The visited window is refreshed after
edits rather than resetting a reader to page one.

Operation scopes now carry identity/revision rather than a document. Complete consumers such as
review explicitly reuse `completeSnapshot` or prepare their complete dependency. Graph/search,
global selection and export retain global semantics; they do not consume only displayed pages.
Favorite status performs an exact entry-key lookup and distinguishes pending/unavailable from
confirmed absence. Detail images require subtree membership and the current workspace/fence.

The opt-in native benchmark supports `--paged-only --sizes 10000,20000 --trials 3`. Each size
uses one closed synthetic seed with two senses/four examples per entry, plus the same semantic,
classification and retained review-history workload as the preceding inventory. Fresh stores
measure first page, next page, selected detail, saved lookup, filtered page and full-store-ready
separately. First favorite and first sense removal each use a cold archive, with removal/full
load on independent copies of that same seed. They have no preceding full-store warm-up.
Cold means empty application/engine caches; the system disk cache is not purged. Timings exclude
fixture construction, repository construction/index setup, assertions and actual frame painting.
Scoped writes still fall back to complete validation on the first command; page readiness is
not a claim that this cost has been removed.

The completed 2026-11-13 checkpoint is recorded in
[the raw samples and source-manifest digests](benchmarks/corpus-browsing-2026-11-13.json).
Release medians in milliseconds, three trials per size:

| Data-ready operation | 10,000 entries | 20,000 entries |
| --- | ---: | ---: |
| First 100 summaries and global count | 86.718 | 159.897 |
| Next page | 17.717 | 22.068 |
| Selected entry detail | 7.128 | 7.177 |
| Exact favorite-status lookup | 1.059 | 1.072 |
| Language/tag filtered page | 95.309 | 204.375 |
| First cold favorite | 4118.337 | 8634.062 |
| First cold sense removal | 4304.373 | 9113.774 |
| Complete store and read index | 4142.490 | 8622.457 |

Every first page returns 300 entry/sense scalar summaries; each selected detail decodes 17
payload rows in this fixture. These are returned-work counts, not counts of every row visited
by SQL's global count/filter. The first local-read prototype still requested `ORDER BY id`
inside its selected-subtree SQL, encouraging a workspace-wide primary-key walk. Removing that
ordering lets the existing parent indexes constrain reads; the codec assembles only the returned
subtree. Intermediate detail medians were 430.983/999.873ms and saved lookups 71.532/183.366ms.
Those are prototype measurements, not the pre-change Dev sidebar's warm in-memory lookup.
The final tag query builds matching sense IDs once before joining headwords. Global tag metadata
is reused across filter changes at the same corpus fence. Only the two creation-order indexes
are added; the existing collection/sense uniqueness constraint already supplies its lookup index.

Six engine integration tests passed, including lossless detail/media checks and a SQL-instruction
regression with 100 versus 2,000 entries. The 74 native checks passed; one visible desktop journey
was intentionally skipped. They cover page-only explanation adoption, cancellation/replacement of
tag reads, retained selection/window after edits/filters and an external generation change without
a repository notification. The performance envelope passed all 48 windows with their count and
review-history postconditions. Product source hashes match the final measurement manifest;
new/changed Swift lines have no lint violations, and diff checks passed. Owned DerivedData,
copied packages, private hosts and synthetic databases were removed. The installed Dev app and
real corpus were not accessed or replaced.

First-page readiness now precedes full preparation, but cold first writes still pay that complete
preparation cost. Tag filtering also retains a corpus-wide JSON tag scan. These are remaining
boundaries for subsequent work; this checkpoint does not claim that every operation is constant
time or that graph/search/global export have become paged readers.

## Certified cold entry writes (2026-11-13)

[ADR 0006](adr/0006-certified-local-entry-writes.md) replaces the cold ordinary text command's
complete-preparation prerequisite with a durable, exact-fence validation certificate. The
engine reads the target subtree through the same lossless detail selector, validates it with
the existing domain rules, checks indexed global IDs/keys and conservative dependency limits,
and reuses the canonical row writer, CAS and pending journal in one transaction. It still
rechecks the complete document media ownership/pin set. The local fragment never becomes a
complete engine cache, document or `VocabularyStore.entries` value.

The archive returns an explicit entry receipt or the ordinary complete result. The store
admits that receipt before notifying other subsystems, refreshes visited pages/detail and
favorite status, and retains one latest owner for immediate explanation adoption. Complete
selection/review/graph/export consumers still request their complete dependency. The existing
workspace test fixture now does so explicitly rather than assuming a favorite loads everything.
Account identity is checked again on the actual detail used to prepare a save; the writer then
rechecks its exact version inside the commit transaction.

An installed database without this derived certificate still needs one complete preparation.
Missing/damaged/stale proof, external canonical/schema/policy changes, enrolled/note-consuming
senses, changed media references, existing interpretation changes and foreign semantic citations
retain complete preparation. The benchmark reports eligible commands and fallback commands
separately. Seeds contain a certificate from their untimed, validated creation; process caches
are empty for each cold command. They contain no image-heavy content or dense merged-alias
workload; media/alias correctness is covered by separate focused tests, not a latency claim.

Version metadata remains readable before content reconstruction rejects corrupt JSON. New
alias/plan expression indexes guard JSON evaluation explicitly. An initial unguarded index
changed corruption-test failures from full validation to index maintenance; that side effect
was removed. Normal content saves/loads remain strict. No universal JSON database constraint
or recovery contract was introduced as a performance side effect.

The [raw samples, comparison and source evidence](benchmarks/corpus-cold-entry-2026-11-13.json)
record twelve windows, three trials at each size. Release medians in milliseconds:

| Data-ready operation | 10,000 entries | 20,000 entries |
| --- | ---: | ---: |
| First 100 summaries and global count | 98.934 | 151.960 |
| Next page | 18.505 | 22.734 |
| Selected entry detail | 7.599 | 7.542 |
| Exact favorite-status lookup | 1.319 | 1.044 |
| Language/tag filtered page | 97.650 | 212.626 |
| Cold translation favorite, valid proof | 31.501 | 48.643 |
| Cold ordinary sense removal, valid proof | 31.856 | 46.775 |
| Cold context favorite, valid proof | 38.347 | 56.950 |
| Cold example append to existing sense, valid proof | 45.266 | 62.811 |
| Cold enrolled-sense removal, full fallback | 4246.983 | 8800.997 |
| Cold favorite without proof, full fallback | 4283.140 | 8926.785 |
| Complete store and read index | 4047.573 | 8454.999 |

Against the preceding matched command windows, 20k ordinary cold favorite changes from
8634.062ms to 48.643ms and ordinary removal from 9113.774ms to 46.775ms. Complete preparation
and tag filtering remain global work. The same-shape seeds were generated independently across
versions; these three observations do not establish a percentile or a hardware-independent
latency guarantee. The preceding 43-operation inventory was not rerun.

Validation passed 119 engine Swift Testing checks and 40 engine XCTest checks. The final signed
private Release host passed 76 native checks; one opt-in visible-desktop journey stayed skipped.
All 72 timing windows and their postconditions passed, including retained 1,000-rating history
on the cold mutation/fallback copies. An initial six-test failure was confined to the shared
workspace fixture's old implicit-full-load assumption; those six tests passed after the fixture
explicitly prepared its dependency. All measured product/test source hashes match the final
tree. New/changed Swift lines have no lint violations, and diff checks passed. Owned DerivedData,
copied packages, private hosts and synthetic databases were removed and cleanup verified. The
installed Dev application and real corpus were not accessed or replaced.
