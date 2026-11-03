# Native Mac Review and Progress UI delivery

Temporary module B delivery record, 2026-11-03. Root integration should consolidate lasting
requirements, provenance, validation and remaining limits into the maintained Mac documents,
then remove this report.

## Branch and scope

- Worktree: `/Users/shadow/.codex/worktrees/mac-ui-review/lingrove`.
- Branch: `codex/mac-ui-review`.
- Frozen baseline: `6873de801b121103ecf57d2cd9fcbc48e7d5df5d`.
- Code/test/localization commit: `588d16f42c4a2d74322c30519b9239f41d76a9fa`.
- Contract: `docs/MAC_UI_SYSTEM.md`; source credit remains in the components and the existing
  `MAC_REVIEW_ACCOUNT_UI_REUSE.md` / `MAC_PROGRESS_UI_REUSE.md` provenance documents.
- No merge, push or installed-app replacement was performed.

The complete assigned presentation surface is adapted: review overview, sense participation,
practice, preparation/front-back editing, source selection/copy/speech affordances, queue,
history, and their sheets; Progress summary, five-week calendar, paged rating chart and all
eight forecast buckets. No new account, storage, scheduling, Markdown or mathematics work was
introduced. Original corpus, menu bar, Settings/account and the two A-owned shared style files
are untouched.

`BuiltInReviewWindowView(session:)` and `NotebookProgressView(repository:isActive:)` retain their
composition interfaces. The XcodeGen project diff adds only references for B's new pure helper
and three independent test files (34 added lines, no build-setting changes), keeping this branch
self-contained. Regenerate the project once after combining both module branches.

## Presentation and ownership

- Review and every assigned sheet inherit native appearance. Forced dark/color-scheme and
  global orange tint have been removed. Native window/control/text backgrounds, separators and
  semantic foregrounds replace the previous material-heavy card chrome. Existing shared
  readable-width and action-style entry points remain compatible.
- Review and Progress use the same title hierarchy, fixed page heading, readable document
  widths and native secondary actions. Forecast switches between stacked and side-by-side
  layouts at constrained/ordinary widths. Calendar emphasis follows Lingrove's existing accent.
- Rating controls, history, rating chart and eight forecast categories retain distinct semantic
  colors and written labels. Native bordered buttons can ignore tint, so rating symbols explicitly
  carry red/orange/green/blue while rating text retains the primary foreground.
- The sense back button only assigns the overview route. Practice has a named **End review**
  action; its material chooser is offered after ending the round. Choosing a sense never calls
  start/end. Start, reveal, rating, undo and source callbacks retain session-owned behavior.
- The preparation sheet owns a `BuiltInReviewDraftPresentationSnapshot`: only editable material
  fields participate in dirty comparison. Preview and front/back navigation do not become edits.
  Cancel asks Keep editing/Discard changes when needed; interactive dismissal is disabled while
  edited or writing. Save still sends the original scoped draft to the existing writer.
- Progress still borrows its app-owned repository and visibility-scoped model. Totals, active
  senses, eligible exercises, civil dates, rating distribution, weekly pages and forecast counts
  come from the existing interfaces. Legend rows are native buttons with selected accessibility
  traits, labels, counts, percentages and existing chart gestures. Empty buckets stay readable.

Seven new BuiltInReview copy keys cover all 15 Mac locales. All existing localization records
are unchanged; ReviewCards and NotebookProgress needed no new copy. English-placeholder checks
passed for BuiltInReview (90 keys), ReviewCards (30) and NotebookProgress (37). The generic
`scripts/localization.py validate` has a pre-existing semantic-key limitation: it compares format
arguments against keys such as `streak.longest`, producing 70 errors for existing Progress keys.
The checked English-value contract is recorded in `catalog-proof.json`; the shared script was
not changed. Catalog key order was restored after validation without changing its semantic JSON.

## Executed validation

All Swift/Xcode/native work held `/tmp/lingrove-mobile-validation.lock`. The signed private host
was **Lingrove UI Review Validation**, bundle ID
`io.ichthyoplanktonzyh.lingrove.mac.ui-review.validation`, with
`LingroveIsolatedValidationHost=true` and XCTest markers. Startup logs confirm production service
startup was skipped. Only synthetic SQLite state was used; no user corpus, real credentials,
TCC, login items, system appearance or installed Dev application was opened or changed.

The ignored `build/validate-ui-review.py` is a checkout-local wrapper around the existing
validator. It uses distinct evidence/cache/host paths and reserved ports 20180–20182. Shared
tracked validation scripts were not modified. Fixed dependencies were copied from the approved
central inputs; TTS used `CMAKE_OSX_ARCHITECTURES=arm64` and `TTS_BUILD_JOBS=4`. Xcode builds used
`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` and only `build/DerivedData` in this tree.

| Check | Actual outcome |
| --- | --- |
| Production SwiftLint, strict | Passed initially and after the rating-symbol correction. |
| Final Debug build-for-testing | Passed; this is compilation, not test execution. |
| `scoped` native selection | 6 test functions, 15 concrete runs, 0 failures/skips. |
| Final `rating-colors` affected rerun | 1 parameterized function, 2 runs, 0 failures/skips. |
| Pure material-baseline test in `draft-checkpoint` | 1 function passed independently. |
| Visible material checkpoint in `draft-checkpoint` | 1 function failed unfinished-state assertion after CUA reported Mac locked; no UI action occurred. |
| Fresh Luna/max read-only review | No confirmed regression; no code/test edits or native operations by reviewer. |

The passing scoped selection exercised real SQL-backed Aqua/darkAqua Review and Progress views,
native preparation sheets, question/answer/finished states, queue/history/text-selection content,
source callback, rating/undo, exact-window/sheet/reveal keyboard guards, hidden/re-enter behavior,
loading/failure/retry/empty Progress, and a forecast with exactly one exercise in every bucket.
It also ran the existing single prepare/save/rate/reopen/undo journey and keyboard policy table.
Unchanged broad storage/FSRS suites were not rerun. The final small rerun verifies both appearances
after explicitly coloring rating symbols. Views were not given a forced SwiftUI color scheme.

Initial test compilation failed on the AppKit protocol import name and a nested Swift Testing
macro; both test-only issues were corrected before successful build-for-testing. The first
in-process action selection then failed five functions (10 parameterized action runs; the pure
baseline test passed). One bounded locator correction still failed its two appearance cases.
The recorded tree showed `NSHostingView<AnyView> children=0` despite visible controls. This action
path was stopped, its source/logs retained under `failed-action-harness`, and the delivered tests
use native rendering/exact-window commands rather than growing another locator framework.

## Evidence and remaining limits

Evidence root:
`/Users/shadow/.codex/worktrees/mac-ui-review/lingrove/build/mac-ui-review-validation/`.

- `delivery-proof.json`: source SHA256 manifest, exact result summaries, host identity and cleanup.
- `native-summary-scoped.log`, `native-summary-rating-colors.log`: passing executed results.
- `native-summary-presentation.log`, `native-summary-native-locator.log`: retained locator failures.
- `native-summary-draft-checkpoint.log`, `onscreen/computer-use-blocked.json`,
  `onscreen/stored-result.json`: locked-screen checkpoint, draft remained open, zero exercises.
- `native-ui/`: 42 cached native content PNGs. Inspected representative light/dark review,
  material, calendar/rating chart and narrow/wide eight-bucket artifacts; final rating icons
  visibly retain all four colors. Native content and appearance inheritance are checked.
- `mac-build-rating-colors.log`, `production-lint-final.log`, `catalog-proof.json`,
  `read-only-review.txt`, and `cleanup.json`: build/lint/catalog/review/cleanup evidence.

Large failed xcresult diagnostic bundles were pruned after exporting the summaries, logs,
AX dump, screenshots and failed harness source. Passing result bundles remain available.

These are NSView cached rendering artifacts. Native toolbar/glass compositor appearance and
pointer operation are not established by these PNGs; cached sheet chrome can contain transparent
or uncomposited regions. CUA attachment was attempted only after verifying the live ready PID,
exact executable path, private bundle ID and isolated-host flag. It returned **The Mac is locked
and automatic unlock could not unlock it**. No manual pass is claimed. Keep editing/discard,
the visible back/End review controls, chart legend selection, week paging, and the combined real workspace journey remain for root's
bounded onscreen acceptance when the Mac is available. All 15 locales were structurally checked;
every locale's visual layout, VoiceOver and actual speech playback were not newly accepted.

A/root must remove the existing dark override from the standalone fallback review controller
and the actual workspace host. B deliberately did not alter A's three native host files. Root
also owns combined appearance/navigation checks against A's final shared action styles. B added
no new theme manager and depends on no unpublished A symbol.

## Cleanup

`cleanup.json` reports all owned paths absent: DerivedData, copied source packages/inference/TTS
inputs, OCR/dictionary outputs, module caches, private host, owned caches/application-support/
saved-state/preferences. No owned host process remains. No `lingrove-ui-review-*` temporary
database directory remains. The approved central inputs still exist and were treated read-only.
Only useful evidence and the ignored local wrapper remain under this tree's `build/` directory.
