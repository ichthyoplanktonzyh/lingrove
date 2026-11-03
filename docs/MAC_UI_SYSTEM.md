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
- Page title, selected sidebar row and visible actions agree. A back arrow performs one
  recognizable navigation action, never silently starts or ends a practice round.
- Preserve unsaved material/sheet navigation guards, source reveal, accepted writer lifetime,
  review keyboard scoping and hidden-destination suspension. Window navigation cannot change
  the active account/workspace or reset a practice merely to refresh its appearance.

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

### Shared card authoring and review journey contract

The shared-authoring checkpoint includes both the entry/journey changes and content/editor
changes accepted in PRODUCT_MODEL.md. Shared authoring supports both batches. Executed evidence
and remaining limits are recorded separately below and in MAC_WORKSPACE.md.

- The outer destinations remain Personal corpus, Review and Progress. Inside Review, Lingrove
  and Anki are equally discoverable targets, while participation and scheduling remain separate.
- The corpus sense shows both targets' actual state and actions. Multi-selection offers explicit
  built-in enrollment and Anki preparation; neither an ordinary corpus save nor Cancel enrolls.
- One material editor supplies source/example selection, templates, ordered question/answer
  content and previews to both adapters. Target connection, deck and remote conflicts remain
  Anki-owned. Editing built-in material does not require an Anki session or connection.
- Ordinary Review navigation opens the overview. Starting a round is explicit. Empty corpus,
  unenrolled corpus, due work, not-yet-due work, paused participation, unavailable material and
  a completed round have distinct primary actions and truthful status.
- Finding material to add and managing existing participation are distinct actions. A selected
  source is not repeated as an unselected row. Practice and completion communicate their actual
  round/scope and provide return, source and built-in Progress navigation.
- User-facing copy is limited to labels, actions, status and errors/confirmations needed for the
  operation. Do not add domain-model, architecture, ownership or unrelated explanatory paragraphs
  to the editor, overview, management screens, Settings or onboarding. Teaching belongs in source
  comments and maintained developer documentation.
- Light/dark native checks must inspect the actual editor, question/answer, overview and target
  navigation. A protected synthetic journey checks save/reopen, explicit enrollment, rating and
  completion against persisted results; screenshots alone do not establish persistence.

### Existing appearance checkpoint

The app environment retains one dependency graph. Presentation borrows account, sync, corpus,
review and Progress owners; appearance work does not construct a second service graph. This
earlier appearance adaptation changed no database/schema, transport, scheduling or shared-package
implementation. Shared material authoring has its own persistence and protocol validation.

| Owner | Responsibility and data flow |
| --- | --- |
| VocabularyWindowController / NotebookWorkspaceHostController | Retain the original corpus, mount one destination, align native title and selection, scope toolbars and inherit the window appearance. Existing review commands route here. |
| SettingsCoordinator / SettingsNavigationModel | Own one Settings window and its route lifetime. External account actions and search select the intended overview/service/sync page. |
| AccountSettingsNavigation | A window-owned child observed by the account pane. It retains URL drafts across pane unmount/Close, reconciles only pristine or explicitly saved pairs, and never grants network authority. |
| AccountPaneView / account sheets / AccountNotebookSyncSection | Borrow the existing services. Native scaffold, row labels, callouts and confirmation present identity, service, workspace, ownership, sync opt-in and recovery as distinct actions. |
| BuiltInReviewWindowView and related views | Borrow the existing frozen session. Overview/Back and End review have explicit meanings; material/source/queue/history sheets inherit native appearance. |
| BuiltInReviewDraftPresentationSnapshot | A sheet-lifetime value of editable material fields. Navigation/preview alone is not dirty; edited Cancel asks Keep editing/Discard. The original scoped draft remains the writer input. |
| ReviewMaterialEditor / VocabularyReviewLayoutEditor | The shared editor borrows neutral recipe/media bindings and source values. The Anki wrapper translates only its plan; source selection, ordered parts, templates and native preview have one implementation. |
| NotebookReviewDestinationView / BuiltInReviewContentView | Equal Lingrove/Anki choices and separate Today/content management. Search misses, no corpus, all content already added, unenrolled, scheduled and unavailable states remain truthful; target switches suspend hidden review work. |
| NotebookProgressDestination and sections | Present the existing visibility-scoped model and immutable statistics. Native cards, adaptable forecast layout, labeled semantic rating/bucket colors and chart interactions retain data meaning. |
| LingroveReadableContentLayout / LingroveNativeActionButtonStyles | Keep their extracted interface names while supplying Lingrove-native widths and bordered/prominent controls. They own no theme manager or service. |

Composition retains VocabularyWindowController.showReview(selection:), its settings/account
callbacks, BuiltInReviewWindowView(session:), NotebookProgressView(repository:isActive:) and
SettingsCoordinator.showAccount(). The earlier appearance checkpoint left original UI/Vocabulary
and menu-bar sources unchanged; the shared-authoring checkpoint may adapt their review entry
points while preserving the corpus navigation and existing native appearance.
Source provenance remains in MAC_REVIEW_ACCOUNT_UI_REUSE.md and MAC_PROGRESS_UI_REUSE.md; their
extraction tables describe origin, while this document defines current presentation.

The explicit first-save action is Add to review. Existing-material Save does not change
participation. Completed-round feedback requires a started round with accepted answers, names
its actual scope, and offers Today/Progress navigation. Preparation Cancel asks before discarding
edits and publishes no Card/media/enrollment writes. There is no persistent unenrolled-draft UI.

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

## Current checkpoint evidence

The newer shared-authoring checkpoint is integrated into main with both planned batches. It
adds the shared editor and typed media persistence, Lingrove/Anki destinations, Today/content
management, corpus/batch actions, explicit round completion and concise Settings/Home surfaces.
The original appearance checkpoint below remains historical evidence, not a claim that the
new material persistence was unchanged. Current ownership and exact counts are maintained in
MAC_WORKSPACE.md and `build/review-integration-validation/integration-proof.json`.

The Mac delivery passed 33 definitions / 46 cases and an actual synthetic CUA journey through
Discard, enrollment, rating, completion, Progress and source return. Final module presentation
ran in both appearances. Main's signed Debug build-for-testing and 11-definition / 12-case
combined selection passed without failures/skips after the content empty-state correction.
The 125-key review catalog has all 15 locales; strict production SwiftLint passed. Useful native
screens and module evidence are preserved beside the combined proof. Physical audio, real Anki,
VoiceOver and the protocol-v2 backend/mobile rollout remain explicitly outside this acceptance.

The completed two-module wave was integrated from baseline 6873de80. Temporary dispatch/delivery
records were consolidated here and removed. Module A executed 61 test definitions / 64 concrete
cases, no failures/skips; module B executed six definitions / 15 cases, then two affected rating
cases. Those are separate module runs, not aggregate claims about every historical attempt.

Integration completed a signed arm64 Debug build-for-testing, strict production SwiftLint and
all seven affected catalogs' complete 15-locale/English-placeholder checks. Twelve native test
definitions / 16 cases passed after combination, including real workspace/Settings ownership in
Aqua and darkAqua, material/destination rendering, Progress and existing navigation/write guards.

The actual isolated main-window journey passed: source sense -> explicit enrollment -> Start ->
reveal -> Good -> visible Progress -> retained source corpus -> account footer -> existing
Appearance settings. CUA screenshots showed the real compositor in inherited light appearance.
The native postconditions independently confirmed one enrollment/exercise/rating, reps=1,
Progress reviews=1/active senses=1, original selection retained and Settings visible.

A separate visible account handoff completed service draft/Back/disabled-login/Revert, email,
OTP and synthetic sign-in; it expired before its final done marker, so it remains a failed,
incomplete checkpoint. The first workspace handoff was aborted when CUA reported locked Mac;
its unmet assertions remain failures. A redundant selector probe selected zero tests and is not
counted as a pass; its target had already passed in the combined run. No broad business suites
were repeated to repair a selector. User-confirmed unlock allowed the final workspace pass.

Keep editing/Discard pointer confirmation, every chart legend/paging pointer action, VoiceOver,
actual speech and every locale's visual layout were not newly accepted. Model/native rendering
and scoped keyboard/draft checks are evidence, not substitutes for unperformed pointer actions.
Real providers/mailboxes/cloud/physical devices remain separate acceptance scope.

Evidence is build/mac-ui-integration-validation/ (combined result, final workspace result and
postconditions, catalog proof, logs and preserved earlier failures). Curated module evidence and
passing result bundles were copied with SHA256 checks before module worktree archival. The final
Dev artifact and cleanup have separate proof files there. No module or test touched the installed
user app, corpus, real credentials, login items, TCC or macOS appearance. Root installation, when
performed, is recorded separately and retains user data.
