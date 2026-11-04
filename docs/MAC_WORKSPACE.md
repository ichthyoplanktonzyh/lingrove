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

### Shared card authoring and material ownership

The same `ReviewMaterialEditor` serves Lingrove and Anki. Its sheet-owned bindings contain the
ordered layout, selected example, optional name and temporary image/audio preparation. The view
borrows the existing VocabularyStore for source images/templates and an adapter-provided speech
action. It never owns an Anki connection or decides enrollment. `VocabularyReviewLayoutEditor`
is now only the Anki-plan adapter; profile/deck/fields/conflicts and receipts remain Anki-owned.

| Boundary | Lifetime, collaborators and flow |
| --- | --- |
| LingroveNotebook ReviewMaterialPlan / ReviewMaterialResolver | Portable recipe values and deterministic source resolution. Both adapters consume the same ordered text/block/audio result; gap and template source selection have one implementation. |
| BuiltInReviewDraft / BuiltInReviewDraftPresentationSnapshot | One preparation sheet copies the frozen scope, recipe, authored faces, generated baseline and temporary media. Recipe edits refresh only untouched generated faces; Cancel/discard has no enrollment or media write. |
| BuiltInReviewMaterialPreparation | Sheet-lifetime audio generation/audition and image staging. It borrows the app's existing speech owner and returns immutable prepared bytes; it does not create another speech service or publish files. |
| BuiltInReviewSession / BuiltInReviewIO | One app-owned session and serial IO worker. Frozen commands cross to short shared-engine connections; accepted writers survive ordinary Close and drain on Quit. Scoped reads return saved image/audio bytes and corpus participation status. |
| LingroveNotebookCardLink / LingroveNotebookReviewMediaStore | Durable recipe/source/generated ownership and workspace-owned PNG/WAV/MP3 bytes. One transaction commits material, media, Card and participation, or rolls all of them back. |
| BuiltInReviewFace | Generated faces render ordered shared parts natively; authored/retained faces retain saved Markdown. Only fenced local media bytes are used; mounting a face neither downloads a resource nor generates speech. |
| NotebookReviewDestinationModel / NotebookReviewDestinationView | The existing corpus window retains tool selection. Switching to Anki suspends built-in reading, speech and keyboard admission, without moving participation or history. |
| BuiltInReviewOverviewState / BuiltInReviewSource | Pure projections of immutable facts, shared by presentation and services. Overview has no completed-round state; source resolution stays outside SwiftUI. |
| VocabularyBuiltInReviewSection / BuiltInReviewBatchView | Source detail reads target state and navigates; batch confirmation retains frozen actions/intent IDs. The engine resumes existing groups and commits the complete selection atomically without duplicating history. |
| HomeLearningBuiltInReviewDemo | One mounted sample owns its uniquely named synthetic repository and production review session/editor. It drains writes and removes only its own state on disappearance. |

First preparation commits through the explicit **Add to review** action, atomically creating
material and participation. Editing an existing exercise uses **Save**, retaining participation,
scheduling and ratings. There is no separate durable unenrolled preparation-draft store. Saving
a template is its own explicit operation and does not save or enroll the open card draft.

The engine creates schema 39 and transactionally upgrades live schema 38 without rewriting corpus,
authored faces or ratings. Recipe and hidden/generated media follow explicit account ownership
copy and retained history. Source/example/block loss or stale source audio blocks ordinary queue
admission; the user can repair material or explicitly continue using retained saved faces.

Rich material uses the existing review lane's version-2 wire contract, including exact media ACKs
and bounded resource envelopes. Unsupported old-service replies leave pending work intact. The
independent backend/mobile repository must adopt the reviewed shared snapshot, schema and wire
contract before real rich-material cross-device sync is available. Local codec/apply tests do
not establish server adoption or physical-device acceptance; no service was deployed here.

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
The 2026-11-03 regression checkpoint executed six navigation-model checks, six workspace
integration checks and the validation-host policy check (13 passes), plus two real sidebar
navigation cycles in the isolated on-screen host (one passing test). The latter retained one
synthetic rating and restored the corpus toolbar. Its system log contained no SwiftUI
publication-during-update warning; transient AppKit negative-geometry diagnostics remained,
with no observed visual or responsiveness failure. Evidence is under
`build/mac-workspace-validation/*navigation-hang*` and
`build/hang-diagnosis-20261103/`; these checks do not use the installed user's corpus.
The installed-app follow-up also identified the same synchronous binding publication in
SettingsSidebarView. SettingsNavigationModel now defers sidebar requests while keeping explicit
search/link routing synchronous, and SettingsCoordinator revokes pending input on window Close.
The Settings follow-up executed 34 model tests and one native close/lifetime check, all passing.
Its four-pane on-screen check also passed with no publication-during-update warning. Two earlier
UI harness attempts counted initial/restored pane notifications as clicks; the bounded reruns
fixed only observation deduplication and the private host's initial AppStorage value. Those failed
attempts remain in the evidence, separately from the final pass; business/storage suites were not
repeated for those harness-only changes. In total the two sidebar checkpoints executed 50 final
passing checks, including their two focused on-screen tests.

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

Review uses the extracted cards, answer controls, queue and material editor. Progress uses the
original streak/calendar, paged stacked-rating chart and selectable schedule donut/legend.
Necessary adapters use AppKit, the shared sense model and local image bytes. Community,
leaderboards, provider-management UI, rewards, premium and telemetry are outside this surface.
Full UIKit/MarkdownUI/RaTeX math/table rendering parity is not implemented.

## Validation and practical limits

The shared-authoring integration is recorded in `build/review-integration-validation/`. The
four shared commits and Mac delivery `7862606e` were applied to main after `19d4ccbe`; root
`44f76173` also distinguishes search misses and fully enrolled corpus from an empty corpus.
The signed arm64 Debug build-for-testing passed. The combined selection executed 11 test
definitions / 12 parameter cases, with no failures or skips: rich material save/reopen and
authored faces, image/audio bytes, batch resume/history, explicit overview/round states,
practice editing, inherited-appearance editor/tool navigation, retained corpus/sheets/source,
navigation during rating refresh, Anki authored fields and the existing Anki sample.

The Mac module separately executed 33 definitions / 46 cases, then a presentation-only rerun
in two appearances. Its actual CUA journey completed edit → Cancel/Discard → explicit enroll →
Start → reveal → Good → scoped completion/next due → Progress → source return. Stored results
confirmed one exercise/rating, reps=1 and Progress reviews=1. These executions overlap with the
combined selection and are not added as unique tests. Core final model/engine/cloud logs retain
18 focused passes plus 11 existing material/history passes. The core lead additionally delivered
18 earlier CardLink/enrollment passes whose original log had been overwritten; the delivery's
reported 47 distinct passes are distinguished from the retained final logs.

Strict production SwiftLint passed; the 125 BuiltInReview keys and existing workspace/progress
catalogs have complete 15-locale and placeholder checks. Module reports, useful result bundles,
final screens and logs were copied and SHA256-verified before worktree archival. Combined
`integration-proof.json`, `catalog-proof.json`, `evidence-sha256.json` and `cleanup.json` retain
the precise counts, inputs and boundaries. DerivedData, copied package/module caches and the
private validation host/preferences were removed and verified absent; canonical pinned inputs
remain available. No installed application or real user data was accessed or replaced.

Backend/mobile version-2 adoption, real Anki, physical audio/system voice, VoiceOver and every
locale's visual layout remain separate acceptance limits. Pointer image/audio import, every
management/Settings control and Keep editing were not newly accepted by the visible journey.
No new Release latency, production deployment or installed-app claim is made by this checkpoint.

After that checkpoint, the user explicitly requested the Dev update. Root built arm64 Release
from `177d9e8c`, verified the existing signing requirement, used the application's own Quit to
drain writes, and retained the previous app, Notebook directory, SQLite snapshot and preferences
before replacing the existing installation. Normal startup upgraded the live database from 38
to 39; hashes/counts of existing corpus/review columns matched, and configured preferences were
unchanged after decoding JSON. Quality counters, font cache and window geometry remain ordinary
runtime state. Startup reported all services started with no app/runtime/model errors; the actual
installed UI showed both review targets. No review enrollment or rating was performed to verify
the update. `build/review-dev-update/installation-proof.json` records the installed path, backup,
binary identity, schema and preservation checks; its separate cleanup proof verifies removal of
DerivedData/copied package/module caches. This installation is distinct from module validation
and does not establish backend/mobile protocol-v2 adoption or new latency measurements.

Run scripts/validation/validate-mac-workspace.py for bounded native build/test/onscreen checks.
It copies approved fixed dependencies into this checkout and uses a disposable host, SQLite
and preferences. All Swift/Xcode/native operations hold /tmp/lingrove-mobile-validation.lock.
Build with ARCHS=arm64 ONLY_ACTIVE_ARCH=YES and DD only in build/DerivedData; clean copied
dependencies, module caches and private hosts when done. Never use the installed user app,
real credentials/data or permissions to make module checks pass.

Private signed validation copies carry LingroveIsolatedValidationHost plus a .validation
bundle identity. LingroveTestHostPolicy keeps them isolated even if a UI tool reopens an
expired XCTest host. Ordinary Dev/release startup stays unchanged. Before CUA attachment,
check the fixture's ready PID is alive; getApp can launch an app that has already exited.

Latest integration evidence is build/mac-w4-integration/integration-proof.json. Module evidence
was reduced to final useful logs/results/figures before completed worktrees were archived.
The integration ran 12 selected native checks successfully; after the toolbar fix, its five
workspace checks plus the validation-host policy check passed. The unchanged statistics engine
has 45 delivered regression passes, and its native model/storage/render checks have five passes.
These are separate executions, not an assertion that every historical attempt passed.

Mouse enrollment, reveal and Good rating were observed in the real workspace. The earlier wave's full visible
Progress/settings journey did not finish within the fixture deadline; two failed handoffs were
retained as failures and further automation stopped at the timebox. Progress storage/model and
native chart rendering have executed evidence, but this does not replace the missing complete
mouse journey. The toolbar leak observed on screen was fixed and its native regression passed.

Real cloud/mailbox/provider, physical dual-device cloud UI, VoiceOver, real Anki, system speech,
old macOS and every locale's visual layout were not newly accepted in this checkpoint. No
latency benchmark or Instruments result is claimed. Build/signature/artifact and cleanup results
are recorded separately in dev-app-proof.json and cleanup.json beside the integration proof.

After the mobile repository split, the canonical Mac checkout independently completed a native
build-for-testing and six workspace/validation-host tests (0 failures/skips), plus 121 repository
tool checks. An arm64 Release Lingrove Dev 0.7.2 build and strict signature verification passed;
the preserved preview is build/mac-main-preview/Lingrove Dev.app. This adds no new mouse-journey
claim. Split/build evidence lives in build/repository-split/ and build/mac-workspace-validation/;
completed wave evidence remains separate. The snapshot shared-code owner and private mobile
repository are described in [REPOSITORY_BOUNDARIES.md](REPOSITORY_BOUNDARIES.md).

The native UI unification checkpoint now adapts all added account/sync/review/Progress surfaces
to Lingrove's system appearance, native controls and Settings hierarchy. Account URL drafts are
window-owned; external account navigation returns to overview and search reaches the actual
subpage. Review Back and End review are explicit, and edited material Cancel asks before discard.
The combined two-appearance native checks and the actual enrollment/rating/Progress/corpus/account
journey passed. This closes the earlier main-window compositor journey gap; the separate account
OTP handoff remains incomplete after its deadline. See MAC_UI_SYSTEM.md for exact evidence and
remaining pointer/locale/accessibility limits.

The subsequent normal account-entry checkpoint closes that account OTP handoff gap with a
discoverable login/create-account entry, a truthful missing-service route and a native email/code
flow. Focused account rules/lifecycle/native checks passed (31 definitions / 36 concrete cases),
and CUA completed missing-service navigation plus configured draft, Back, Close, resend and
synthetic sign-in journeys. Final native results retained no selected workspace or ownership
proposal and left sync disabled. Build defaults remain empty and real mailbox/service deployment
is deferred. MAC_UI_SYSTEM.md records the exact scope and build/mac-account-login-validation/
holds the result bundles, renderings, postconditions and cleanup proof.

### Built-in review flow checkpoint (2026-11-03)

The review-flow refinement keeps the equal Lingrove/Anki destination and existing engine. It
adds an explicit corpus-add destination with atomic batch confirmation, retained search/filter
and return origin, participation filters independent of material warnings, enrollment feedback,
action-led due overview, one effective question/answer preview with optional recipe controls,
and identifiable history rows. See MAC_UI_SYSTEM.md for the maintained interaction contract.

Validation evidence is in `build/review-flow-validation/`: signed Debug build-for-testing passed;
16 targeted definitions executed as 24 cases with zero failures/skips (experience, session,
keyboard and native presentation). One additional CUA-driven protected journey passed against
`io.ichthyoplanktonzyh.lingrove.review-flow.validation` and a private synthetic notebook. It
searched harbor, entered detail and returned with search retained, expanded card options,
manually authored the prompt, verified that exact text in preview and practice, enrolled,
rated Good, inspected identifiable history, checked next-due presentation and returned to source.
Persisted assertions confirmed one active sense/card/rating, reps=1 and Progress reviews=1.

Aqua/darkAqua content captures were inspected; native bitmap captures do not reliably include
system toolbar compositing, so the live CUA journey separately checked the editor controls in
light appearance. All 134 review catalog keys cover 15 locales; localization validation and
strict lint on changed production Swift passed. This checkpoint does not validate real Anki,
physical audio, every localized layout or VoiceOver. No installed user application or corpus
was opened/replaced; no schema, scheduler or synchronization contract changed. DerivedData and
the private copied host were removed after validation (cleanup evidence beside the test results).

On 2026-11-04, the user authorized installing this review-flow checkpoint into the existing
Lingrove Dev bundle. The arm64 Release candidate passed strict signing and the installed app’s
signature requirement. Clean Quit preceded a Notebook/SQLite/preferences/previous-app backup;
startup preserved schema 39, all 37 protected corpus/review table fingerprints and every existing
preference value. The new process and Settings window were observed. Installation evidence and
the exact uncommitted source manifest are in `build/review-flow-dev-update/`; build caches were
cleaned afterward. No enrollment or rating was performed on the user's corpus for this update.

## Note 模板实现（2026-11-04）

新选入的内置复习采用共享 Note / Note Type / Card Template 模型；语料字段动态投影，
Card 保留独立历史。原生模板编辑与实际复习共用 HTML/CSS renderer；视觉迭代边界见
[REVIEW_TEMPLATE_DESIGN.md](REVIEW_TEMPLATE_DESIGN.md)。不转换既有练习，不触碰安装中的 Dev 数据。

## Navigation geometry checkpoint (2026-11-04)

Corpus/Review/Progress now keep the native toolbar region attached. Destinations with no
commands use an empty icon-only toolbar; they never retain hidden corpus actions. The split
container owns destination sizes instead of accepting changing SwiftUI intrinsic minima.
Settings also owns its window size. Account's overview/service/workspace pages use a local
44-point header and retained path/drafts, avoiding a nested NavigationStack changing the window
chrome on push/pop. No account/auth/sync operation is performed by that navigation.

The synthetic native probe reproduced 32-point viewport changes before the fix. Its 96 sampled
states after the fix retained exact window frames/content rects: corpus 1000×620 inside a
1000×672 window, account 900×560 inside a 900×592 window. The initial broader run passed 15/16
checks; the Close test raced initial AppStorage restoration. After settling first appearance,
only that affected test was rerun and passed. Geometry, draft/account appearance, corpus toolbar
restoration and hidden-page lifecycle checks passed. Evidence: `build/navigation-stability-validation`.
No installed Dev app/data was used. This checkpoint does not include the following Anki changes.

## CLI installation and capture checkpoint (2026-11-04)

The installer updates a verified earlier helper symlink of the same product, preserving unrelated
commands and Dev/production separation. CLI 4 / transport protocol 2 verifies app path, capabilities
and a mailbox-lease instance before sending material. Legacy requests receive an upgrade error
without reaching the archive. Notebook scope remains an independent account/notebook guard.
Category/node discovery supports compact summaries; capture receipts include classification
memberships. CLI.md and the portable skill describe the single-capture workflow and stop on
client/schema/server contradictions instead of removing scope fields.

Signed build-for-testing and the four focused CLI suites passed: 28 definitions / 37 concrete
cases. After adding legacy-envelope rejection coverage and closing the fixture's store before
deleting its SQLite files, the affected transport suite passed again (24 definitions / 25 cases).
Evidence is under `build/mac-workspace-validation/`, with preparation/Release/deployment evidence
under `build/cli-validation/`. Skill validation and linked capture JSON checks passed.

The user separately authorized updating the installed Dev app and testing their real notebook.
The arm64 Release build retained the existing installation path and developer signing requirement;
normal Quit preceded replacement. The old helper returned an explicit upgrade error. CUA then
clicked Install CLI in General settings and observed Installed; the symlink resolved to the running
build and its status returned protocol 2 and notebook scope. One user-requested classification
membership was previewed, committed and read back (revision 13 → 14), retaining the original sense
and both examples. No synthetic material, enrollment or review rating was added to the user notebook.
DerivedData, copied package caches and the private test host were removed and cleanup verified.
