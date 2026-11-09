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
fields. Revision-bound CLI updates can replace the explanation without editing the headword, personal
notes, source evidence or review ownership. Stored interpretation/generation receipts remain evidence;
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
