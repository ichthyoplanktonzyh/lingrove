# Native personal Progress UI source adoption

Baseline: `a151c519369ea7dd4bb423ba127713e7e8e62348`. Upstream refers to the checked-in,
historical `Nibomo/apps/ios/Flashcards/Flashcards/Progress/` tree at that baseline. The current upstream-derived tree is in the private mobile repository.
MIT attribution remains in every extracted source header and the already bundled
`Lingrove/Resources/NibomoUI-LICENSE.txt` (Copyright © 2026 Kirill Markin).
No upstream file or license is modified.

| Upstream component | Actual Mac file | Treatment |
| --- | --- | --- |
| `Sections/ProgressReviewsSection.swift` | `Lingrove/UI/NotebookProgress/NotebookProgressReviewsSection.swift` | Extracted paged stacked `BarMark` chart, selected-day binding, rating filter, reset token, weekly arrows and four-rating legend. Mechanical type prefixes, AppKit colors and local string table. |
| `Sections/ProgressReviewScheduleSection.swift` | `Lingrove/UI/NotebookProgress/NotebookProgressReviewScheduleSection.swift` | Extracted `SectorMark` donut, angle selection, wedge toggle, dimming, empty caption and eight-bucket legend. Binds directly to shared `UserReviewSchedule`; Card wording becomes exercise wording. |
| `Sections/ProgressStreakSection.swift` | `Lingrove/UI/NotebookProgress/NotebookProgressStreakSection.swift` | Extracted five-week grid, first-weekday headings, day cells, flame/today/future treatments and accessibility date/count labels. Mechanical AppKit colors; summary receives the local engine value. Freeze bank/alert removed because this local notebook has no such reward system. Longest streak uses the real summary. |
| `Sections/ProgressCardModifier.swift` | `Lingrove/UI/NotebookProgress/NotebookProgressCardModifier.swift` | Extracted 16-point card padding/radius; AppKit control background replaces UIKit grouped background. Applies only within Progress. |
| `Sections/ProgressLoadedSections.swift` (personal cards only) | `Lingrove/UI/NotebookProgress/NotebookProgressView.swift` | Business binding: same streak → reviews → schedule order; local summary and explicit empty/error/retry states. No community sibling cards. The destination borrows the app repository and owns a read model, never an app graph. |
| `Model/ProgressSnapshotTypes.swift` (calendar/chart values only) | `Lingrove/Models/NotebookProgress/NotebookProgressPresentation.swift` | Mechanical type prefixes and nonisolated immutable values. `NotebookProgressContent` couples real SQL data to its derived display values. Cloud/community snapshot models are omitted. |
| `Presentation/ProgressReviewChartPaging.swift` | `Lingrove/Support/NotebookProgress/NotebookProgressChartPaging.swift` | Pure extraction: week grouping, civil-date padding, current-page default and full seven-day x domains. Mechanical prefixes/imports/isolation. |
| `Presentation/ProgressSnapshotFactory.swift` (`makeProgressStreakWeeks`, chart-day mapping, upper bound) | `Lingrove/Support/NotebookProgress/NotebookProgressPresentationFactory.swift` | Extracted five-week expansion and y upper bound. Business binding takes a validated shared-engine snapshot and its frozen calendar. No separate mobile cloud validation/model graph. |
| `Presentation/ProgressFormatting.swift` (through schedule formatting) | `Lingrove/Support/NotebookProgress/NotebookProgressFormatting.swift` | Extracted date/weekday/percentage formatters, rating palette and exact eight-bucket palette. Local Mac catalog/rating titles and exercise nouns. Community freshness/profile functions omitted. |
| `Assets.xcassets/AccentColor.colorset/Contents.json` | `Lingrove/Support/NotebookProgress/NotebookProgressFormatting.swift` | Original RGB `(1, 0.404, 0.098)` is a destination-local accent. Calendar flames/today rings cannot inherit the Mac's system accent or alter the corpus page. |
| `Presentation/ProgressBadgePresentation.swift` (personal flame/overflow treatment) | `Lingrove/UI/NotebookProgress/NotebookProgressStreakSection.swift` | Extracted flame-vs-outline, reviewed-today border and 99+ badge treatment. No UIKit image probe, freeze bank, leaderboard or interactive reward state. |
| `Aggregation/ProgressDateSupport.swift` | Existing shared engine `Review/Statistics/ProgressDateSupport.swift`, called by new `NotebookProgressAggregation.swift` | Reused unchanged: civil dates, 140-day display range, strict local dates, timezone/DST-safe forecast boundaries, streak evaluation and day states. A zero-capacity/zero-earning policy prevents invented freezes. |
| `Aggregation/ProgressAggregation.swift` (local event-day/rating reduction) | `Packages/LingroveNotebookEngine/Sources/LingroveNotebookEngine/Review/Statistics/NotebookProgressAggregation.swift` | Business binding: persisted effective notebook events, recorded event timezone with frozen fallback, four-rating counts and original schedule ranges. All-history totals/streaks are independent of the bounded display chart. No server base/pending overlay cache. |
| `Model/ProgressCoreTypes.swift` | Existing shared engine `Review/Statistics/ProgressCoreTypes.swift` | Shared values reused without public semantic changes: `ProgressDay`, `ProgressSummary`, `ProgressStreakDay`, `UserReviewSchedule`, bucket stable order. |
| `Resources/Localization/Foundation.xcstrings` personal Progress keys | `Lingrove/Resources/NotebookProgress.xcstrings` | Extracted existing translations for supported Mac locales. `es-ES` maps to Mac `es`; lead supplied Traditional Chinese and notebook-specific copy for all 15 locales. Existing `BuiltInReview` rating translations reused. No external translation service. |

## Notebook binding and ownership

The engine query in `Queries/LingroveNotebookEngine+NotebookProgress.swift` reads active workspace,
notebook/revision and account generation together, then uses one SQLite read transaction for
corpus grouping, complete event history, undo exclusion and currently admitted exercises.
`Models/Review/NotebookProgressSnapshot.swift` is the portable immutable result/fence boundary.
It does not expose an app service, cache or cloud transport.

History follows `notebook_review_exercises` → `notebook_review_enrollments`, including retained
historical relationships. It does not require a live source, Card or enrollment status. SQL `EXISTS`
prevents merged ownership from multiplying events. Every undone event is excluded from the same
four-rating distribution used by totals and streaks. Independent Cards, merely linked Cards,
Anki metadata and other notebooks/workspaces never enter the series.

Forecast follows the existing queue eligibility predicate plus this notebook's exact managed
exercise/link relationship. It excludes paused/withdrawn, deleted and unavailable material;
explicitly retained material remains eligible. The original buckets are New, Today (including
overdue), 1–7, 8–30, 31–90, 91–360 days, 1–2 years, Later. Civil-day addition defines boundaries.
Senses are resolved through merge aliases and counted separately from exercise Cards.

`Services/NotebookProgress/NotebookProgressIO.swift` owns short native read-only connections to
the repository's same file. Its actor performs all full reads, aggregation and calendar expansion.
`NotebookProgressModel.swift` owns active-only subscriptions, a bounded metadata monitor and one
cancellable read identity. It captures a repository-connection fence before dispatch and checks it
again before publishing; account generation, notebook revision, local SQL changes and external
commits invalidate old results. Hiding the page revokes its lifetime and clears content. Re-entry,
repository notifications, app activation, local day/timezone changes and external commits reread
storage. There is no automatic sync, write, new endpoint, schema or long-lived repository.

The frozen `now`, calendar, timezone and first-weekday inputs belong to one returned snapshot.
Recorded review timezones retain Nibomo's event-day policy; missing zones use that frozen timezone.
The entire effective history determines totals/current/longest streaks; the original 140-day range
limits only chart presentation. All local summaries are exact for the selected notebook, so they
do not inherit the mobile cloud fallback's “approximate” label.

## Deliberately not extracted

- `FlashcardsStore`, `CloudSessionRuntime`, server-base/pending overlay persistence or HTTP refresh.
- Leaderboards, streak leaderboards, profiles, friends/invites, community participation and sign-in UI.
- Freeze-bank rewards, recharge, service-backed buttons, purchase/subscription UI and telemetry.
- Mobile navigation, UIKit wrappers, haptics or the upstream global screen/service graph.
- The original corpus/menu/settings/account pages. The workspace integrator injects only
  `NotebookProgressView(repository:isActive:)` into its optional content factory.

Current ownership, validation and limitations are maintained in [MAC_WORKSPACE.md](MAC_WORKSPACE.md).

The native UI unification stage retains these source interactions and statistics while adapting
page headings/cards, native backgrounds/accent, chart legends and narrow forecast layout to
Lingrove. Semantic rating and eight-bucket colors remain labeled. MAC_UI_SYSTEM.md defines the
current presentation and distinguishes cached native renders from actual compositor evidence.
