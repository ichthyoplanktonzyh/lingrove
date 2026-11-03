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

## Implementation seams and parallel ownership

The app environment retains one dependency graph. Presentation borrows account, sync, corpus,
review and Progress owners; appearance work must not construct a second service graph. There
is no database/schema, transport, scheduling or shared-package implementation work in this wave.

The two module leads implement complete assigned modules, then validate/fix as a batch:

| Owner | Source and responsibility |
| --- | --- |
| A: navigation/account | UI/NotebookWorkspace, Models/NotebookWorkspace, Services/Presentation/{VocabularyWindowController,NotebookWorkspaceHostController,BuiltInReviewWindowController}, App/Coordinators/SettingsCoordinator, SettingsContainer/Sidebar/Category/Navigation/Index as needed, account Settings panes/sheets/components; window appearance and account navigation ownership. |
| B: review/Progress | UI/BuiltInReview, UI/NotebookProgress, review-specific UI/NibomoPresentation, presentation-only Support/BuiltInReview and Support/NotebookProgress; complete destination and sheet adaptation with existing session/model interfaces. |

A alone owns the existing shared LingroveReadableContentLayout.swift and
LingroveNativeActionButtonStyles.swift in UI/NibomoPresentation. Preserve their existing
symbols, initializer signatures and style entry points so B can build against the frozen base.
No new cross-lead Swift dependency is required: native semantic colors and existing interfaces
are sufficient. Other shared settings infrastructure changes remain A-owned and scoped to this
goal. B owns the remaining review-specific extracted presentation. Neither lead edits the other's
source, App/Core, Services/{Account,Notebook,NotebookSync,BuiltInReview,NotebookProgress}, shared
Packages, original UI/Vocabulary or the menu bar. Escalate a concrete necessary exception.

Keep these existing composition interfaces compatible:
VocabularyWindowController.showReview(selection:), its settings/account callbacks,
BuiltInReviewWindowView(session:), NotebookProgressView(repository:isActive:),
SettingsCoordinator.showAccount() and the existing app-owned service/session/model contracts.
The root agent owns the final App/Core composition and combined validation changes if needed.

A owns account/workspace/settings tests and their fixtures, including the mixed
UI/Settings/LingroveReusedPresentationTests.swift. B owns review/Progress UI tests in distinct
files and may use existing fixtures without changing A's fixture interface. For localization A
owns NotebookWorkspace/Account/NotebookSync/NibomoAccount tables and necessary Settings copy;
B owns BuiltInReview/ReviewCards/NotebookProgress tables. New shared default-table copy needs
coordination rather than concurrent edits. Neither lead edits this contract or MAC_WORKSPACE.md;
final integration updates maintained documentation and removes temporary delivery reports.

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

Each lead uses gpt-6.1-sol/max in its managed worktree. Optional fresh gpt-6-luna/max reviewers
may only review or execute tests, never write implementation/tests. The root agent does not
poll, inspect work-in-progress, redirect or take over implementation; leads proactively report
completion or ask concrete questions. No push, deployment, external accounts or Mac installation
replacement belongs to a module delivery. Final integration produces a reviewable Dev build.
