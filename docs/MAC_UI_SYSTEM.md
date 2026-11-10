# Native Mac UI system

This is the maintained UI contract for the native Mac application. The corpus page and the
existing Settings panes provide the visual baseline. Account, sync, built-in review and
Progress now adopt that baseline; earlier instructions to retain their unadapted Nibomo
appearance are superseded. Business identities, account consent, persistence and review
rules remain as described in PRODUCT_MODEL.md and MAC_WORKSPACE.md.

## Navigation and window ownership

- Keep the menu bar's current appearance, commands and shortcuts. Existing review commands
  already route through the app-owned controller to the corpus window; preserve that route.
- The reusable corpus window has exactly Personal corpus, Review and Progress destinations.
  Retain the complete original corpus page, its internal navigation, toolbar and editors.
- Settings and account footer actions reuse SettingsCoordinator's one Settings window.
  The account footer communicates local use or the real account/sync state. Opening it is
  navigation, never authentication, ownership adoption or sync opt-in.
- Account and sync belong to the existing account Settings destination. Status and normal
  actions should be immediately understandable; service/advanced configuration is secondary.
  Subpages have an explicit, predictable return path. External account navigation reaches its
  intended page even if Settings previously displayed another account subpage.
- The account overview always exposes **Sign in or create an account**, including builds without
  a deployed service. The native email -> eight-digit-code sheet supports Back, resend, errors
  and cancellation. Missing/invalid service values show a truthful unavailable state and a route
  to secondary service settings; opening login makes no request. No unsupported provider buttons
  are presented. Custom service provenance stays visible without full URLs in the normal form.
- The Mac composition root reads a paired, validated build default from Info.plist. This source
  tree leaves both values empty. Saved custom services take precedence; saved pairs remain pinned
  across default changes. Use app default is an explicit confirmed service switch, and removing a
  service suppresses fallback after relaunch. Unsaved URL drafts block sending/verification/sync,
  and account login leaves workspace selection, local ownership and sync opt-in separate.
- Page title, selected sidebar row and visible actions agree. A back arrow performs one
  recognizable navigation action, never silently starts or ends a practice round.
- Preserve unsaved material/sheet navigation guards, source reveal, accepted writer lifetime,
  review keyboard scoping and hidden-destination suspension. Window navigation cannot change
  the active account/workspace or reset a practice merely to refresh its appearance.

## Sense detail content

The sense detail reads the current definition, one rich explanation, examples and adopted semantic
links. Agent capture writes `sense.explanation` into sense content; it rejects example-level meaning
fields. Revision-bound CLI text-fragment edits preserve explanation formatting and images. Whole-body
plain replacement is restricted to an unformatted, image-free body. Metadata, examples and semantic
links have explicit operations rather than implicit changes to the headword or review ownership. Stored interpretation/generation receipts remain evidence;
they are not competing definitions or fallback review answers.

Keep the existing icons, native components, typography and callout styling. Dictionary lookup stays
in the detail page. Reading retains speech, copy, sense switching and semantic navigation. One Edit
command in More edits the selected sense, without renaming its headword. Structural commands (new or
merge sense, move usage, mapping/pattern CRUD) belong to organization tools, not the sense reader.
Review stays explicit through compact Lingrove/Anki entries; card lists and editing belong to Review.
No general legacy compatibility fallback is part of this change. The user explicitly authorized a
one-time migration and replacement of their current Dev installation; review-data compatibility
was excluded. The original application and complete notebook/media backup remain recoverable.

## Appearance and controls

- Follow the system-resolved appearance used by the existing Lingrove windows. Do not add a
  new app theme preference or manager for this wave. Opening/navigating a page does not mutate
  NSApp appearance, window appearance, preferences or another hosting subtree's color scheme.
- Remove forced dark preferences/host overrides from the new account, sync, review and their
  sheets. Set inherited appearance correctly at the owning host. Original inline popup chrome
  has a separate intentional appearance scope; do not change it with a global search/replace.
- Use semantic foreground, separator and native window/control backgrounds. Interactive accent
  follows the existing application/system accent rather than forcing Nibomo orange throughout.
  Rating, warning/error and schedule colors retain their semantic distinctions and non-color
  labels. Do not erase chart meaning while adapting colors for light and dark backgrounds.
- Account and sync use SettingsPaneScaffold, SettingsRowLabel and existing callout/form patterns
  where applicable. Reuse their typography, grouping and spacing instead of a separate settings
  framework. Preserve settings search anchors and current service-draft/confirmation guards.
- Review and Progress use consistent page headings, readable content widths, secondary actions,
  adaptive cards and sheet controls. Review material remains legible in both appearances;
  images, text selection, copying and speech controls retain their functions.
- Preserve the actual statistics, calendar/chart paging, selections and eight schedule buckets.
  Empty, loading, failure, local-only and disconnected states remain truthful and actionable.
- Keep useful existing accessibility identifiers and keyboard semantics. New copy uses the
  destination's existing localization table and all 15 Mac locales; inherited credit remains.

## Presentation ownership

### Review journey contract

The current default enrollment and shared Note model are maintained in
[REVIEW_TEMPLATE_DESIGN.md](REVIEW_TEMPLATE_DESIGN.md); explicit Anki publication is described in
[ANKI_NOTE_SYNC.md](ANKI_NOTE_SYNC.md). Both targets remain discoverable with independent histories.
Ordinary Review navigation shows an overview and starts a round only through an explicit action.
Empty, unenrolled, due, scheduled, paused, unavailable and completed states remain distinct.
Use native light/dark appearance and keep source navigation, cancellation, keyboard scoping and
user edits intact. Product-facing copy presents actions, status and necessary errors, leaving
architecture explanations to developer documentation.

### Presentation boundaries

The app environment retains one dependency graph. Presentation borrows account, sync, corpus,
review and Progress owners rather than creating another service graph.

| Owner | Responsibility and data flow |
| --- | --- |
| VocabularyWindowController / NotebookWorkspaceHostController | Retain the original corpus, mount one destination, align native title and selection, scope toolbars and inherit the window appearance. Existing review commands route here. |
| SettingsCoordinator / SettingsNavigationModel | Own one Settings window and its route lifetime. External account actions and search select the intended overview/service/sync page. |
| AccountSettingsNavigation | A window-owned child observed by the account pane. It retains URL drafts across pane unmount/Close, reconciles only pristine or explicitly saved pairs, and never grants network authority. |
| AccountPaneView / account sheets / AccountNotebookSyncSection | Borrow the existing services. Native scaffold, row labels, callouts and confirmation present identity, service, workspace, ownership, sync opt-in and recovery as distinct actions. |
| BuiltInReviewWindowView and related views | Borrow the existing frozen session. Overview/Back and End review have explicit meanings; material/source/queue/history sheets inherit native appearance. |
| Review Note and type editors | Own window-lifetime drafts; saving uses the shared Note/type boundary and Cancel discards the draft. |
| Legacy material editors | Continue to support existing recipe-based paths; new Note enrollment and sending use the shared Note/type model. |
| NotebookReviewDestinationView / BuiltInReviewContentView | Equal Lingrove/Anki choices and separate due-now/content management. Search misses, no corpus, all content already added, unenrolled, scheduled and unavailable states remain truthful; target switches suspend hidden review work. |
| NotebookProgressDestination and sections | Present the existing visibility-scoped model and immutable statistics. Native cards, adaptable forecast layout, labeled semantic rating/bucket colors and chart interactions retain data meaning. |
| LingroveReadableContentLayout / LingroveNativeActionButtonStyles | Keep their extracted interface names while supplying Lingrove-native widths and bordered/prominent controls. They own no theme manager or service. |

Composition retains VocabularyWindowController.showReview(selection:), its settings/account
callbacks, BuiltInReviewWindowView(session:), NotebookProgressView(repository:isActive:) and
SettingsCoordinator.showAccount(). Review entry points preserve corpus navigation and the existing native appearance.
Source provenance remains in MAC_REVIEW_ACCOUNT_UI_REUSE.md and MAC_PROGRESS_UI_REUSE.md; their
extraction tables describe origin, while this document defines current presentation.

Enrollment is explicit; editing saved material does not change participation. Completed-round
feedback requires a started round with accepted answers and names its actual scope. Canceling an
unsaved edit or preparation does not commit its draft or implicitly enroll a sense.

## Validation and user-data protection

The installed Lingrove Dev now contains real user corpus data. Feature validation uses only
synthetic databases/preferences/credentials and disposable signed .validation hosts. Do not
open, copy, reset, replace or relaunch the user's installed app or corpus during module work.
Do not change login items, TCC, system appearance, real accounts or provider configuration.

All Swift/Xcode/native operations hold /tmp/lingrove-mobile-validation.lock. Each checkout
uses its own build/DerivedData and copied input/module caches, cleaning them before delivery.
Use fixed inputs from /Users/shadow/lingrove/build when available; never restore old mobile
Git history. The existing validate-mac-workspace.py is a reference, not shared edit ownership.
Checkout-local ignored wrappers may select distinct hosts, evidence roots and fixture ports:

- A: Lingrove UI Shell Validation; io.ichthyoplanktonzyh.lingrove.mac.ui-shell.validation;
  isolated account/sync fixture ports 20080–20099.
- B: Lingrove UI Review Validation; io.ichthyoplanktonzyh.lingrove.mac.ui-review.validation;
  isolated fixture ports 20180–20199.

Keep LingroveIsolatedValidationHost=true and the .validation identity on private copies, and
keep XCTest markers. A lock prevents simultaneous native execution; unique host namespaces
also prevent one lead's later cleanup from retiring another lead's host/state. Do not edit the
shared tracked validator; deliver necessary combined harness adjustments as integration notes.

Focused native rendering/navigation checks should exercise inherited Aqua/darkAqua on private
hosts and account-to-another-Settings-pane transitions, without changing macOS settings. Cover
relevant existing draft/keyboard/source/statistics guards. Root integration verifies a small
set of real UI journeys across the combined destinations; avoid a broad E2E matrix or rerunning
unmodified storage/FSRS suites for cosmetic changes. Automation infrastructure remains limited
to two corrective reruns or 20 minutes per issue, then retain evidence and state the gap.

## Validation limits

Synthetic native checks and their historical evidence do not establish real Anki, production
service deployment, physical-device sync, VoiceOver, every locale, or final visual acceptance.
The Note implementation and its specific validation limits are recorded in
[REVIEW_TEMPLATE_DESIGN.md](REVIEW_TEMPLATE_DESIGN.md). Historical checkpoint reports remain in Git.

### Sense detail validation

The content consolidation passed 8 focused shared-package tests and 46 native Mac tests with no
failures or skips. Native coverage includes CLI writes/replay, revision checks, rich-content
persistence and reader/editor rendering. The Dev Release build was installed at the existing app
path after a successful signature check and one revision-bound corpus migration. Its existing
icons/components and in-page dictionary remain. Bitmap-only test captures were insufficient for
complete visual QA; the user chose to inspect the installed interface themselves. Test DerivedData
and the disposable validation host were removed. No review-data migration was implemented.

### Continuous explanation editing

The explanation is edited in one native rich-text buffer with one selection and undo history.
The existing paragraph/heading/bullet picker, bold/italic and image icons are reused in a single
toolbar. Images and captions retain the existing media registry; imported bytes live for the draft
so deleting and undoing an image cannot discard its staged data. Save publishes only referenced
media. Native IME composition is committed before taking the save snapshot.

`VocabularyRichTextEditor` owns platform selection and commands; `VocabularyRichTextCodec` converts
native attributes to portable UTF-16 inline marks. Shared reading and HTML rendering consume those
same marks. Paragraph/media identities remain an internal storage detail, not separate input boxes.
The semantic section contains node links only. A migration to move existing pattern/association
explanations into the sense body with their exact meaning/pattern scope has passed a dry run;
relation identities and restrictions are preserved. Deployment was initially paused, then authorized
on 2026-11-09 and completed as recorded below. Favorite writer alignment is described below;
the reported existing Working record was repaired from its already-saved interpretation.

The continuous editor passed 7 focused native tests covering formatting, Unicode, image identity,
undo/redo, rich paste, selection, IME commit and save/reopen. Shared formatting and wire-codec suites
passed 15 tests; the environment-gated native wire interop bridge was skipped. These checks do not
establish cross-device sync or visual acceptance. Build-for-testing also succeeded; test DerivedData
and the disposable validation host were removed after validation.

The current Dev installation is local-only. Inline marks are supported by local storage, portable
backups, HTML and the shared wire codec. The deployed backend's strict content schema and older mobile
clients still need the matching rich-text contract rollout before syncing formatted text; this change
performs no backend deployment or mobile snapshot update.


### Explicit sense consolidation and capture writes

The Mac list supports dragging one sense onto another within the same headword, plus a row-menu
alternative. Existing row components and icons remain. The target retains its summary, rich body,
notes, tags and semantic associations; source examples move with translations and provenance.
The hover label states which content survives. One undo action restores the pre-merge document and
removed images while the notebook scope/revision is unchanged. A later write invalidates that
receipt. The same shared policy handles CLI version 2 `merge`; MCP uses its existing reviewed
preview/commit path. There is no additional inference request or automatic semantic classifier.

Favorites now persist the supplied meaning on the sense and already available explanation in its
body. Late explanation completion fills untouched content only; manual clears and merged target
content remain authoritative. Explicit adoption edits the sense definition. Manual creation makes
an explicit new sense instead of identifying one by its wording, notes or tags. Generic CSV/TXT
import, mappings, preview UI and parsing were removed; original backup restoration remains.

Validation: build-for-testing succeeded. Six new merge/capture/undo cases and 73 related native
cases ultimately passed (79 distinct cases across the focused/regression/corrected runs). Initial
regression failures exposed stale fixture/expectation assumptions, including a test-only array
index crash after removing an example; the affected cases were corrected and rerun successfully.
Coverage includes the real bundled CLI, dry-run/replay, revision/scope conflicts, persistence,
removed image restoration, semantic relationships, delayed explanation writes and retained review
receipts. All 12 MCP bridge tests passed, and the repository CLI skill validator passed.
This source checkpoint did not include on-screen drag verification or backend/mobile rollout.
Test DerivedData and the private host were removed after verification.

### Dev and private MCP rollout, 2026-11-09

The user subsequently authorized installing this checkpoint. A signed Dev Release was built from
`8111e6eb` and replaced the existing Dev installation in place, retaining its designated signing
requirement and bundled CLI path. The previous application, notebook/media, preferences and private
MCP runtime were backed up before replacement. The corpus remained unchanged across app replacement.

One revision-bound CLI transaction then moved existing pattern/association explanation text into
sense bodies and repaired the reported blank Working definition from its single saved interpretation.
It added 84 body blocks across the content migration and adjusted 39 senses in total. Existing content
blocks, entry/sense/example identities, media bytes and shared semantic nodes were preserved. Pattern
notes and association nuance were cleared only after their text was retained in the sense body;
actual restrictions and relationships remained. Integrity and foreign-key checks passed. Existing
review identities/history remained, while ordinary generated material refreshed through the normal
save path; no separate review-data migration was performed.

The private MCP runtime and guide were copied from the repository and its server/tunnel restarted.
Configuration, credentials, drafts and the CLI/app destination were retained. The connected MCP
returned the new Dev process identity, the `merge` schema and the updated guide. This verifies the
actual existing connection, beyond a local health probe. On-screen drag feel and cross-device
behavior remain unverified. Release DerivedData was removed after installation checks.


### Click selection after adding drag support

The initial merge interaction attached `onDrag` to every sidebar sense row, including single-sense
headwords that cannot have an eligible same-headword merge target. Native mouse-event A/B checks
reproduced missed List selection with that drag modifier, while identical plain rows selected.
Single-sense headwords now retain unmodified native List selection. Draggable child senses explicitly
handle a completed tap through the notebook's selection callback; drag/drop continues to use the
same revision-scoped merge path. Existing icons, components and corpus data are unchanged.

A permanent UI regression sends mouse down/up through AppKit to both text-side and trailing row
areas, with and without dragging enabled. It verifies repeated selection and that clicks never
merge. That test (both argument cases) and the existing selection-persistence test passed in an
isolated native host; build-for-testing also passed. The before/after probe used synthetic rows and
no user corpus. This fixes an input-dispatch regression, rather than changing dictionary or model
execution. The matching Dev Release is installed at the same path after signature/content checks.


### Menu-only consolidation and saved-capture actions, 2026-11-10

The user chose to remove drag-to-merge after trying its interaction. Sidebar rows now use native
List selection without drag/drop modifiers, and the existing context-menu merge keeps its explicit
target, account/revision checks and undo receipt. CLI/MCP merge behavior is unchanged.

Saved favorite menus offer only Show in vocabulary. The old Remove this saved usage command was
removed from that surface; deletion is performed in the sense detail (delete sense, or edit/delete
an example and save). Examples remain supporting sense content, not independently managed capture
units. The glossary, list/export labels and walkthrough use Example / 例句 consistently.

This is a source-only checkpoint at the user's request. Do not replace the running Dev, bundled
CLI or private MCP runtime until the user requests deployment. No live corpus changes are needed.

Build-for-testing and 9 focused native tests passed for this checkpoint. Coverage includes actual
mouse clicks on the production notebook list, selection persistence, merge/undo and revision
conflicts, detail-editor example deletion across reopen, and the saved-favorite walkthrough's
read-only navigation. No Dev/CLI/MCP deployment or live-data mutation was performed. Test DerivedData
and the disposable host were removed after validation.


## CLI/MCP sense authoring checkpoint — 2026-11-10

The source now exposes canonical headword/sense reads: current definition, plain explanation text,
saved-image references, examples with provenance and semantic links. Historical generated copy
and native text styling stay out of Agent reads. Saved-image fetches require the original notebook
scope and sense ownership; MCP emits native PNG content. Internal part IDs support safe edits and
do not introduce separate explanation editors or any UI/icon/component change.

Revision-bound `contentEdits` preserves untouched styles/images; whole-body plain replacement
rejects styled or image-containing content. Example edits/removals and node link/unlink changes
are explicit sense operations. `remove` reconciles sense dependents while retaining shared nodes
and independent evidence. Capture/append share source-ID ownership and translation-variant rules;
identical sentence text alone does not merge sources. Obsolete duplicate prose fields are rejected.

Dry runs/receipts show canonical before/after changes. The archive validates references before
constructing a preview and bounds the receipt before commit. Resource discovery comes from CLI
schema, removing the retired collections advertisement. The new contract is CLI 5 / protocol 3;
MCP source package is 1.3.0 and must later deploy with the matching app/helper.

Build-for-testing and all 32 selected native CLI/capture tests passed (including parameterized
cases), plus 10 shared content/evidence tests and 14 MCP bridge tests. Published batch/capture
JSON schemas passed validation, including source-reference scope requirements. Strict SwiftLint
passed for changed app/CLI sources; the CLI skill validator and diff whitespace check passed.
Evidence is in `build/cli-sense/` (native run 3, build 6, shared log, lint and schema check).
The validation caught and fixed preview-before-validation error classification, and the previous
protocol's error-envelope response. Private fixture notebooks were used throughout.

No installed Dev app, CLI link, private MCP runtime, account configuration or live corpus was
updated. The running client has not been used to verify protocol 3. Repository DerivedData and
the private test host/state were removed; dependency source inputs and validation logs remain.


## Batch detail reads and practice capture — 2026-11-10

CLI `vocab read --entry-ids ID,ID` / `--sense-ids ID,ID` and MCP `notebook_read(entryIDs|senseIDs)`
accept 1–100 distinct IDs of one kind. The archive captures one snapshot, validates the original
optional notebook scope, resolves every requested ID, and returns complete canonical entries/senses
in request order with a common revision/scope. Missing IDs fail the entire read; mixed/empty/duplicate
or excessive selectors fail input validation. One cumulative pre-projection budget and the existing
encoded wire bound protect the batch; large MCP JSON retains complete pagination. Images retain
the existing scoped single-image retrieval path. Reads never write receipts or advance revisions.

Normal practice capture still searches existing material, saves expressions/senses/examples and
semantic classification in one capture, then verifies the receipt IDs. Batch readback reduces
round trips without replacing that flow or adding inference/review enrollment. Everyday corpus
management now has query, full batch reads, atomic batch writes, edits, associations, merge and
removal within the agreed user/Agent-organized model; no automatic sense consolidation is added.

Build-for-testing and 7 targeted native tests passed, including ordered entry/sense details,
missing IDs/scope mismatch, aggregate budgets, image references, practice capture/classification
reuse and batch readback, unchanged capture replay, and protocol admission. All 16 MCP tests
passed, including one-request batch routing, invalid selectors and lossless large-result readback.
CLI schema/help discovery, changed-source SwiftLint, the skill validator and whitespace checks
passed. Evidence is under `build/cli-batch-read/` (build 2, native run 1). Validation used private
synthetic notebooks; no live Dev, installed CLI or private MCP update was performed. DerivedData
and private validation host/state were removed after checking results.


## Suggested tag deletion — 2026-11-10

Sense-editor tag suggestions are the union of saved sense tags, not a built-in catalog. Their
existing add chips now offer a context menu containing only the localized Delete action. The
command immediately removes the exact tag from every sense in the original notebook, without a
confirmation dialog or additional copy. New tags still use the existing input; the selected
chip's × still removes only the current draft association. No chip style/icon or other shared
TagChip consumer changes.

`VocabularyStore.removeTag` carries the editor's original scope into one archive transaction.
The shared sense editing policy changes tags only, updating timestamps for affected saved records;
no match is a no-op. After a successful deletion, the open editor rebases only that tag in its
baseline and draft, preserving unsaved fields and unrelated concurrent-edit conflicts. Cancel
still discards the form draft; it does not undo an explicitly completed global tag deletion.


Validation: build-for-testing, changed-source strict SwiftLint and all 3 targeted native tests
passed (2 persistence/scope/draft tests plus the existing notebook/editor render test). Synthetic
fixtures verified all-sense removal, unaffected examples/explanation/images/other tags, a no-op
repeat, persistence after reopen, stale-scope rejection and preserved concurrent-field conflicts.
The context action is compiled into the production editor; no live-user menu click or data
cleanup was performed. Evidence is under `build/tag-delete/` (build 1, native run 1). The private
host and DerivedData were removed after validation. No Dev/CLI/private MCP update was installed.
