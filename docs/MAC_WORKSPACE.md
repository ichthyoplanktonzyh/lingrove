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

The actor performs aggregation off MainActor. The model checks scope/revision/generation and
the repository connection's external/local change token before publishing. While visible, a
two-second metadata probe detects unannounced external writes; unchanged tokens do not trigger
decoding or aggregation. Notifications, activation and date/timezone changes also refresh.
Hidden pages cancel subscriptions/reads and clear content. Empty history and load failure have
distinct UI; failure is never presented as a successful zero count.

### Corpus save and sync

Capture, editing, CLI, sync and review use one durable corpus. Ordinary entry saves prepare
the target subtree, reuse writer-owned validated projections and commit through the common
CAS/journal/media/source-refresh transaction. Connection caches are derived values guarded
by scope/revision/generation, SQLite data_version and local changes; they are not write authority.
Structural/import/restore/remote operations retain their complete validation paths.

Account authentication does not adopt or upload local content. Workspace selection, ownership,
explicit local acceptance and sync opt-in remain separate operations. Corpus/media/review lanes
have independent status and retry behavior. Network waits do not hold SQLite transactions;
late account callbacks and commands retain their original generation. Unsaved translations,
autocomplete context and screen content do not enter corpus sync.

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
