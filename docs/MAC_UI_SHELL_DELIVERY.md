# Native Mac UI shell/account delivery

This is a temporary module delivery record for root integration. Consolidate lasting behavior,
provenance and validation limits into the maintained Mac documentation, then remove this report.

## Branch and scope

- Worktree: `/Users/shadow/.codex/worktrees/mac-ui-shell/lingrove`
- Branch: `codex/mac-ui-shell`
- Frozen baseline: `6873de801b121103ecf57d2cd9fcbc48e7d5df5d`
- Implementation commit: `1f8f0635babf5ce2229c470b75241bd1af20ad9b`
- Contract: [MAC_UI_SYSTEM.md](MAC_UI_SYSTEM.md)

The complete assigned shell/account module is implemented. The notebook window retains the three
outer destinations, the entire original corpus host and its toolbar, sheet/deep-link arbitration,
hidden-page suspension and review keyboard fences. The sidebar uses native selection, its footer
shows local use or the actual retained identity/sync state, and the native window title follows the
visible destination. Settings/account actions retain the existing SettingsCoordinator callback seam.

Account, service configuration, sync, email/code and workspace selection use Lingrove's existing
SettingsPaneScaffold, row labels, callouts and native controls. Account/session actions are primary;
service configuration is a secondary page. The account navigation path is explicit: external
showAccount returns to the overview, and search lands on the session, service or sync page with its
real anchor. Native back navigation returns to the account overview.

The window-level navigation retains URL drafts while panes unmount and Settings closes. A changed
saved service refreshes pristine drafts; unrelated edits survive. A visible unsaved draft blocks
sign-in/session retry/sync requests until it matches the saved pair. Service configuration keeps its
confirmation and now repeats the proposed API/auth destinations in that alert. Explicit Revert
restores the saved pair. Local ownership, conflict choices, first-cloud-copy decisions and sync
opt-in remain separate actions using the existing controller and displayed expected snapshots.

All account/sync forced-dark and orange preferences have been removed. Settings and standalone/
embedded review hosts inherit the owning native window; navigation does not change NSApp, window
appearance, theme preferences or another hosting subtree. The shared action-style entry points now
use the same bordered/prominent native controls as existing Settings and preserve their signatures.
The readable-content layout retains its symbols and initializer signature.

Seven new localized keys cover all 15 Mac locales: three Account, three NotebookSync and one
NotebookWorkspace key. Existing translated catalog entries and Nibomo attribution/license remain.

## File and ownership boundaries

| Boundary | Responsibility, ownership and data flow |
| --- | --- |
| `UI/Settings/Account/AccountSettingsNavigation.swift` | A child owned by SettingsNavigationModel for the coordinator's lifetime. It stores page paths and URL drafts; it receives saved configuration snapshots and never authenticates or owns a service. Keeping it separate limits URL keystroke observation to the account pane. |
| `SettingsNavigationModel`, `SettingsContainerView`, `SettingsIndex`, `SettingsCoordinator` | One Settings window and route owner injects the child into the pane. Search chooses its exact account page before revealing a row; external account navigation resets only the path. |
| `Panes/AccountPaneView.swift` | Borrows the app-owned account/sync facades and the window-owned navigation. It presents identity and ordinary actions, then links to sync and service details. |
| `Account/LingroveAccountServerView.swift` | Borrows draft bindings and owns only confirmation intent. An explicit confirmed save delegates to the existing account service; success normalizes the draft, failure preserves it. |
| `Account/LingroveAccountSignInSheet.swift` | Owns entered text, focus and email/code navigation for the sheet's lifetime. Challenge expiry, cancellation generations and credentials stay with the existing service. |
| `Components/AccountNotebookSyncSection.swift`, workspace chooser/status views | Observe one existing sync controller. The view owns temporary conflict selections and one chooser presentation; controller snapshots remain write authority. Form sections separate workspace, ownership, consent, lanes and cloud-copy recovery. |
| `UI/NotebookWorkspace/NotebookWorkspaceSidebar.swift` | Observes the existing navigation and safe account/sync projection. Footer actions delegate back to SettingsCoordinator. |
| Three owned presentation controllers | Own native host/window appearance and destination lifetimes. They retain corpus hosting, toolbar and accepted-writer behavior while setting inherited host appearance. |
| Two shared `UI/NibomoPresentation` helpers | Presentation-only widths and native button-style adapters. Existing names/entry points remain compatible with the frozen review/Progress baseline. |
| Account/workspace/settings tests and fixtures | Use synthetic services, SQLite and preferences. Native appearance readers observe the actual SwiftUI resolved environment under private AppKit windows. |

App/Core, the menu bar, UI/Vocabulary, business services, databases and shared packages were outside
this module's edits. Review/Progress content remains B-owned; this branch removes their AppKit host
override but does not claim the combined content adaptation before B's delivery.

## Executed validation

Evidence root: `/Users/shadow/.codex/worktrees/mac-ui-shell/lingrove/build/mac-ui-shell-validation`

| Check | Actual result |
| --- | --- |
| Fixed dependency preparation and XcodeGen | Passed. Approved inputs were copied into this checkout. |
| First build-for-testing | Failed on missing explicit Foundation/LingroveCloud imports in the new boundaries; fixed. This was a compile failure, not executed tests. |
| Second signed Debug build-for-testing | Passed for arm64 with ONLY_ACTIVE_ARCH=YES, using repo-scoped build/DerivedData. Source scheme was Lingrove; only a private renamed copy was used for execution. |
| Selected native tests | **61 test definitions passed, 64 case executions**, zero failures and zero skips. The difference is one parameterized test's four cases. |
| Native Aqua/darkAqua inheritance | Passed for account overview, service, return path, email, code, sync/ownership and workspace chooser. The tests set only private NSWindow appearances and read the resulting SwiftUI colorScheme; they do not force a view colorScheme or change macOS appearance. |
| Settings owner/navigation | Passed: one Settings window, account subpage -> external showAccount -> overview, then Account -> Appearance -> Account in each private native appearance. |
| Draft/search guards | Passed, including failed configuration, retained drafts, canonical saved-pair comparison, account/service/sync search routing and existing Settings search scrolling. |
| Workspace guards | Five existing native checks passed, covering retained corpus/toolbar, sheet and source-link protection, hidden destinations, exact-window keyboard admission and accepted writes. |
| Final scoped SwiftLint and diff whitespace | Passed. |
| Catalog coverage | Passed for Account, NotebookSync, NibomoAccount and NotebookWorkspace: complete nonempty translations in all 15 locales. |
| Fresh Luna read-only review | No confirmed product bug found. The reviewer performed no implementation/test edits or native execution. |

Selected suites: AccountSettingsNavigationTests, AccountNativeAppearanceTests,
AccountPaneRenderingTests, MacNotebookSyncPaneRenderingTests, LingroveReusedPresentationTests,
SettingsNavigationModelTests, SettingsIndexTests, SettingsPaneScaffoldTests and
NotebookWorkspaceIntegrationTests. Unchanged storage, FSRS and model-backed eval suites were not
rerun for this presentation module.

The successful execution's primary result is `native-result-1.xcresult`; its final summary is
`native-summary-final-1.log`, and its original command/timestamps are in
`native-test-1-command.json` and `runs.jsonl`. A later accidental reused suffix overwrote the first
stdout file, but the passing result bundle remained unchanged; xcresulttool reported that no
separate console export is available. The result bundle and summary remain the authority.

Useful inspected native rendering evidence:

- `native-ui/account-overview-NSAppearanceName{Aqua,DarkAqua}.png`
- `native-ui/account-service-NSAppearanceName{Aqua,DarkAqua}.png`
- `native-ui/account-email-NSAppearanceName{Aqua,DarkAqua}.png`
- `native-ui/account-code-NSAppearanceName{Aqua,DarkAqua}.png`
- `native-ui/account-sync-ownership-NSAppearanceName{Aqua,DarkAqua}.png`
- `native-ui/account-workspace-chooser-NSAppearanceName{Aqua,DarkAqua}.png`
- Matching JSON records contain the native appearance, resolved color scheme and page title.

Cached AppKit content images verify rendered content and readability. They do not establish the
onscreen compositor appearance of the translucent sidebar/titlebar; the empty sidebar region in
those cached images is a capture limitation.

## Visible handoff limitation and retained failures

The visible native account journey remains **unverified**. The first handoff launch reused an
existing result path, so xcodebuild rejected it with exit 64 before launching the host. The local
wrapper was then run with a unique onscreen suffix. Its ready PID was confirmed alive before CUA
attachment, and the host carried the dedicated `.validation` bundle identity and isolation flag.

CUA reported: “The Mac is locked and automatic unlock could not unlock it.” No mouse/keyboard
journey was performed. The fixture was released through an explicitly marked aborted done record
so its normal teardown could run. Its one opt-in test consequently failed the three unmet journey
assertions (no OTP send/verify and no final Appearance selection). This is retained as a failed,
incomplete automation handoff, not as evidence of a product failure or a manual pass. The actual
stored handoff result records sends=0, verifies=0, signedIn=false, syncEnabled=false, final pane
Account and inherited appearance. No further UI retry was attempted behind the locked session.

Evidence: `onscreen-attempt-1-launch-error.log`, `onscreen-attempt-1-failure.json`,
`onscreen/cua-lock-block.json`, `native-test-onscreen-1.log`,
`native-result-onscreen-1.xcresult`, `native-summary-onscreen-1.log` and
`onscreen/native-result.json`.

Real cloud/mailbox/provider accounts, physical dual-device cloud UI, VoiceOver and every locale's
visual layout were not newly accepted. Combined review/Progress pixels and a short visible settings
journey belong to root integration after B is integrated and the Mac is unlocked.

## Cleanup and integration

All Swift/Xcode/native operations used the shared fcntl lock. This module's host was
**Lingrove UI Shell Validation** / `io.ichthyoplanktonzyh.lingrove.mac.ui-shell.validation`, with
LingroveIsolatedValidationHost=true and XCTest markers retained. Real loopback sync fixtures used
the assigned 20080 range. The installed Lingrove Dev application, corpus, real account state, TCC,
login items and system appearance were not opened or changed.

`cleanup.json` verifies that build/DerivedData, copied SwiftPM/native inputs, module caches, helper
builds, the private host, its app support/cache/saved-state directories and host preferences are
absent, with no owned host process remaining. `fixture-cleanup.json` confirms the handoff database
was removed and its empty preferences file was removed. The two synthetic-preferences cleanup
manifests record removal of only empty test domains created within this host's exclusive test
intervals. Approved central input caches were not modified. Lightweight evidence/result bundles
remain under the ignored evidence root.

Integrate the implementation commit, then this report commit. Regenerate the Xcode project after
combining A and B so independent file additions do not need hand-merged project entries. The shared
button/layout APIs and existing composition methods remain compatible; no App/Core composition
change is required by A. Root owns any combined fixes, a small real UI confirmation, the reviewable
Dev build/installation step and eventual integration into main. This module did not push, merge
main or install/replace the user's app.
