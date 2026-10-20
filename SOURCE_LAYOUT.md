# Cotabby Source Layout

This document is the canonical placement map for production and test source files. It complements
`ARCHITECTURE.md`, which explains runtime ownership and data flow.

Swift folders do not create namespaces. Every Swift file discovered under `Cotabby/` still compiles
into the application module, and every file under `CotabbyTests/` compiles into the test module.
Folders exist so a maintainer can predict where a responsibility lives before searching.

## Placement Rules

1. Choose the top-level architectural boundary first: `App`, `UI`, `Services`, `Models`, or
   `Support`.
2. Choose the product subsystem next, such as `Suggestion`, `Focus`, `Runtime`, or `Settings`.
3. Keep a small cohesive subsystem flat.
4. Add a child folder only when at least two files form a stable responsibility with a predictable
   name. Do not create one-file folders merely to shorten a file list.
5. Put a direct unit test under the corresponding `CotabbyTests/` responsibility. Cross-cutting
   coordinator tests may remain grouped by the coordinator they exercise.
6. Folder moves must not change Swift access control, runtime ownership, or target membership.
   XcodeGen discovers the new paths; regenerate `Cotabby.xcodeproj` after moving files.

## Production Tree

~~~text
Cotabby/
├── App/
│   ├── Core/                         process entry, composition root, lifecycle
│   │   └── ApplicationRelauncher.swift safe relaunch after interface localization changes
│   └── Coordinators/
│       ├── InlineFeatures/           emoji/macro capture arbitration
│       ├── Suggestion/               autocomplete interaction state machine
│       ├── SettingsCoordinator.swift
│       └── WelcomeCoordinator.swift
├── Models/
│   ├── ProductIdentity.swift         localized brand names and independent project destinations
│   ├── Context/                      bounded context and visual-context values
│   ├── Emoji/                        picker and usage values
│   ├── Focus/                        focus snapshots and tracking state
│   ├── History/                      typing-history records, archive, and preferences
│   ├── Input/                        keyboard event values
│   ├── LanguageLearning/             model profiles, traces, languages, sentence/chunk/unit and dictionary contracts
│   ├── Onboarding/                   onboarding templates
│   ├── Permissions/                  TCC permission values
│   ├── Runtime/                      native allocation snapshots and runtime contracts
│   │   ├── Metrics/                  performance and system metric stores
│   │   └── Parameters/               per-model request preferences, sampler overrides and recommendations
│   ├── Settings/                     durable settings and UI-facing settings models, including interface language
│   ├── Speech/                       provider, voice, playback/runtime identities, and durable read-aloud preferences
│   ├── Spelling/                     spelling catalog values
│   └── Suggestion/
│       ├── Request/                  immutable request inputs and configuration
│       ├── Result/                   engine result and client error values
│       └── Session/                  active, paused, and presented session values
├── Services/
│   ├── Context/                      live clipboard acquisition
│   ├── Focus/
│   │   ├── Caching/                  field-scoped focus caches
│   │   ├── Chromium/                 Chromium AX enablement and diagnostics
│   │   └── Resolution/               focus snapshots, geometry, bounded AX walks
│   ├── History/                      typing-history store, recording, and encrypted vault
│   ├── Input/                        event taps and input-source monitoring
│   ├── LanguageLearning/             native/Endpoint tasks, offline lexicon, dictionary sessions, telemetry and editor captures
│   ├── ModelManagement/              model discovery, download, and validation
│   ├── Permission/
│   │   └── Guidance/                 permission overlay and System Settings guidance
│   ├── Power/                        power-source observation
│   ├── Presentation/                 process-level AppKit panels, indicators and owned-window hit testing
│   ├── Speech/                       playback state, isolated audio graph, content-free telemetry, system voices, endpoint audio, and local helper lifecycle
│   ├── Runtime/
│   │   ├── AppleIntelligence/        Foundation Models availability and engine
│   │   ├── Llama/                    autocomplete engine, manager, and KV/cache policy
│   │   ├── Native/                   per-owner native sessions and serialized lifetime/cancellation
│   │   └── OpenAICompatible/         endpoint transport, credentials, and engine
│   ├── Spelling/                     live spell-checking services
│   ├── Suggestion/
│   │   └── State/                    work identity and mutable interaction state
│   ├── Updates/                      manual release checks
│   └── Visual/                       capture, OCR, and visual-context sessions
├── Support/
│   ├── Accessibility/                pure AX and secure-surface policies
│   ├── Context/                      sanitization, relevance, and OCR hygiene
│   ├── Emoji/
│   │   ├── Catalog/                  searchable catalog and synonyms
│   │   ├── Interaction/              query, trigger, picker, and variant rules
│   │   └── Ranking/                  recency and popularity rules
│   ├── Focus/
│   │   ├── Applications/             app, browser, domain, and terminal classification
│   │   └── Capability/               supported-field capability resolution
│   ├── History/                      history retrieval, phrase prediction, scrubbing, import
│   ├── Input/                        composition, key-label, and selection helpers
│   ├── Vocabulary/                   capture identity, local example extraction, merge and search rules
│   ├── LanguageLearning/             exact unit recognition, correspondence projection, pair parsing, prompts and preview/write rules
│   ├── Logging/                      debug options, request IDs, and JSONL handlers
│   ├── Macros/
│   │   └── Evaluators/               deterministic arithmetic/date/unit evaluators
│   ├── Onboarding/                   pure onboarding recommendation rules
│   ├── Presentation/
│   │   ├── Geometry/                 caret, anchor, direction, and overlay layout
│   │   ├── Policy/                   render-mode, fade, and stability decisions
│   │   └── Style/                    ghost text font and color rules
│   ├── Prompting/                    Apple and base-model prompt rendering
│   ├── Runtime/
│   │   ├── Hardware/                 device capability and resource sampling
│   │   ├── BundledRuntimeLocator.swift
│   │   ├── DecodeStopPolicy.swift
│   │   ├── DownloadOutcomeClassifier.swift
│   │   ├── LocalRuntimeResidencyPolicy.swift  when the local model stays loaded
│   │   ├── TokenHealingPlan.swift    bounded word-fragment retokenization at the caret
│   │   └── TokenHealingBuffer.swift  exact byte replay and lossless streamed UTF-8
│   ├── Settings/                     persistence, language normalization, relaunch planning, and settings policies
│   ├── Speech/                       language/voice selection, spoken text, bounded PCM framing and playback queue accounting
│   │   └── InterfaceLanguageNormalizer.swift supported locale mapping without persisted-value mutation
│   ├── Spelling/                     extraction, language, SymSpell, and typo rules
│   ├── Suggestion/
│   │   ├── Acceptance/               insertion safety and strategy
│   │   ├── Output/                   normalization, confidence, and seam cleanup
│   │   ├── Request/                  availability, debounce, and request construction
│   │   ├── Session/                  tail reconciliation and exhausted-tail state
│   │   └── Streaming/                partial coalescing, monotonic text, presentation timing
│   └── Utilities/                    small cross-subsystem value helpers
└── UI/
    ├── Components/                   application-wide reusable views
    ├── InlineFeatures/               emoji picker and macro reference surfaces
    ├── MenuBar/                      menu-bar status and popover content
    ├── Onboarding/
    │   └── Welcome/                  composed welcome flow and step views
    ├── Overlays/                     SwiftUI overlay content
    └── Settings/
        ├── Components/
        │   ├── Controls/              settings editors, pickers, and previews
        │   │   └── InterfaceLanguageSectionView.swift interface selector and restart notice
        │   └── Structure/             pane scaffolds, rows, cards, and search results
        ├── ModelManagement/           shared catalog, browser, folder, installed-file and connection views
        └── Panes/
            ├── About/                 product and acknowledgement panes
            ├── Apps/                  app detail presentation and reusable per-app shortcut rows
            └── Engine/                engine pane and backend-specific extensions
~~~

Files left directly inside a subsystem are intentionally its root owners or a small cohesive set.
For example, `SuggestionEngineRouter.swift` remains at `Services/Runtime/` because it coordinates all
three backend folders, while `FocusTracker.swift` remains at `Services/Focus/` because it owns the
whole focus lifecycle rather than one resolution or caching technique.

## Test Tree

`CotabbyTests/` mirrors the production responsibility after removing the leading `Cotabby/`. For
example:

~~~text
Cotabby/Support/Suggestion/Output/SuggestionTextNormalizer.swift
CotabbyTests/Support/Suggestion/Output/SuggestionTextNormalizerTests.swift

Cotabby/Services/Runtime/Llama/LlamaSuggestionEngine.swift
CotabbyTests/Services/Runtime/Llama/LlamaSuggestionEngineStreamingTests.swift

Cotabby/App/Coordinators/Suggestion/SuggestionCoordinator.swift
CotabbyTests/App/Coordinators/Suggestion/SuggestionCoordinatorPredictionTests.swift
~~~

Tests that exercise several production values may stay at the nearest shared subsystem root. Evals
remain under `CotabbyTests/Evals`, and shared fixtures remain under `CotabbyTests/TestSupport`.

## Per-App Settings

- `Models/Settings/PerAppBehavior.swift` describes optional app overrides. The existing
  `PerAppShortcutOverride` persistence record carries them alongside shortcuts, preserving old
  settings data. `SuggestionSettingsModel` publishes the UI state and projects immutable behavior
  maps into `SuggestionSettingsSnapshot`.
- `Support/Settings/PerAppSettingsResolver.swift` resolves inherited mid-line and typo behavior;
  `AppSettingsList.swift` merges configured, historical, excluded and running applications without
  owning AppKit state. Their direct tests live under `CotabbyTests/Support/Settings/`.
- `UI/Settings/Panes/AppsPaneView.swift` presents that list. `Panes/Apps/AppSettingsDetailView.swift`
  edits one app through the environment-owned settings and history stores;
  shortcut summaries link to the central Shortcuts pane. `PerAppShortcutRowsView.swift` is hosted
  there through `Components/Controls/AppShortcutSection.swift` and reuses the shared recorder. These views
  use the existing settings scaffold, rows and callouts. Opt-in rendering checks live under
  `CotabbyTests/UI/Settings/`.
- `SuggestionRequestFactory` carries app instructions separately from global notes. Both prompt
  renderers consume the same immutable request value, and the base renderer gives app notes their
  own bounded section. `CotabbyTests/Support/Settings/PerAppInstructionsTests.swift` checks that
  boundary and default-prompt compatibility.
- `TypingHistoryStore` owns app-scoped encrypted deletion and the existing full-history lifecycle.
  Its generation and write-sequence guards invalidate older imports and queries before publishing
  a successful delete. `CotabbyTests/Services/History/PerAppHistoryDeletionTests.swift` covers races,
  write failure, quit flushing and global-deletion error isolation.

## Unfinished-Word Interaction

- `Support/Suggestion/Request/CaretWordContext.swift` distinguishes a still-typed token from a
  delimiter-committed word. `TypoGate` and the correction replacement planner consume this value;
  pausing alone never makes correction eligible.
- `Support/Suggestion/Output/CompletionSeamGuard.swift` returns the same presentation decision for
  streamed and final output: wait for the first word, reject a malformed join, show a word ending,
  or show a phrase. A recognized completed word keeps its following phrase even from a one-letter
  prefix; unknown names and jargon can still show a conservative word ending.
- `Support/Suggestion/Request/SuggestionRequestFactory.swift` applies the optional
  `suggestWithinWords` preference to new ordinary and speculative requests. The completion settings
  domain persists the choice, while active sessions remain free to follow matching typing.
- `Services/Suggestion/State/SuggestionInteractionState.swift` holds a narrow range of typed
  characters awaiting Accessibility publication. `SuggestionSessionReconciler` tolerates only an
  older matching prefix during this handoff, so a typed space preserves the following words without
  treating unrelated edits as acceptance. Correction sessions never participate in type-through.
- `Models/Suggestion/Session/ActiveSuggestionSession.swift` separates the full prediction from
  the visible acceptance boundary. An uncertain word ending can retain following words without
  offering them early. The `showFollowingWords` completion preference uses the same boundary to
  show one word at a time; even full acceptance inserts only the current visible offer. Matching
  typing consumes the buffered prediction, while streaming may extend it without revising it.
- `Support/Suggestion/Session/SuggestionContinuationPlan.swift` constructs hypothetical completed
  or corrected text and its exact publication target. A virtual separating space asks for the
  next words rather than another ending; it never edits the host field. The coordinator's
  `+Continuation.swift` owns one cancellable lookahead and attaches it to a terminal word ending,
  or holds it behind a correction until the editor publishes that correction. The live context
  buffer remains anchored to observed text throughout this work.
  Additional preaccept lookahead is limited to on-device engines; configured endpoints retain
  already-generated phrases but do not receive the new hypothetical-edit requests.
- `Support/Spelling/WordPrefixIndex.swift` supplies immutable exact-prefix candidates and bounded
  document/glossary vocabulary. `SymSpellCorrector` builds its index on the existing background
  dictionary queue; fallback never uses spelling edit distance or changes typed letters.
- `Support/Suggestion/Streaming/TypingCadence.swift` measures recent inter-letter intervals and
  controls presentation timing independently of generation debounce. `SuggestionStreamingState`
  memoizes exact-word checks and closes the stream when a final result arrives.
- `Support/Suggestion/Streaming/TypingPredictionCandidate.swift` tracks matching typed characters
  against one on-device request and validates their exact Accessibility publication before rebasing
  the remaining text. `SuggestionCoordinator+TypingPrediction.swift` owns that candidate and its
  expiry timer. The default-on `predictAheadWhileTyping` setting controls retention independently
  of streaming display; disabling it cancels retained work through the settings snapshot lifecycle.
- `Support/Suggestion/Session/SuggestionDismissalMemory.swift` remembers explicit dismissal for at
  most 15 seconds in the same field and text context. It is bounded and never persisted.
- `App/Coordinators/Suggestion/SuggestionCoordinator+WordCompletion.swift` adapts these pure values
  to the existing spell checker, dictionaries, settings, and cancellable presentation work.

Direct tests mirror those folders. `SuggestionCoordinatorWordCompletionTests` replays pauses after
individual letters, malformed streams, fallback acceptance, dismissal/cache behavior, and cancellation
against the actual coordinator with synthetic OS and engine boundaries. The phrase accuracy replay
uses the committed typo gate and final display policy, but deliberately excludes local fallback so
its score remains attributable to the model. Timing replay and coordinator interaction tests cover
presentation and acceptance separately; model-only scores do not represent the complete experience.
`SuggestionCoordinatorContinuityTests` covers buffered acceptance, hidden streaming growth, cached
word restoration, correction publication, and late cancellation. `TypingExperienceEvalTests` drives
the production coordinator with the real local engine and a synthetic editor, recording visible
and buffered text plus actual requests in `build/eval/typing-experience.json`. It does not measure
third-party editor AX behavior or visual placement.

## Adding Or Moving A File

1. Identify its single dominant responsibility using the map above.
2. Place or move its direct tests with it conceptually.
3. Update tracked Markdown links and any scripts containing physical paths.
4. Run `xcodegen generate` and commit the regenerated project.
5. Run SwiftLint, a build, and `build-for-testing` before opening a pull request.

When a file seems to fit several folders, that usually signals either a cross-subsystem contract
that belongs in `Models`, a root orchestrator that should remain above its collaborators, or a type
that owns too many responsibilities and should be split by behavior rather than hidden by nesting.

## Conversation Context Freshness

- `Support/Focus/FocusedInputPollingSignature.swift` distinguishes navigation using live URL, title,
  placeholder and field geometry, while ignoring typing and volatile AX wrapper tokens. The focus
  resolver reads these facts before comparing sessions; surface metadata is not frozen in a cache.
- `FocusedInputSessionIdentity` in `Models/Focus/FocusModels.swift` carries that boundary through
  generation, acceptance and speculative work. Prediction memory has a session key separate from
  the geometry/style key so another conversation cannot restore an old suggestion.
- `VisualContextCoordinator` refreshes both backend profiles using their existing capture limits.
  Excerpts expire six seconds after capture starts, even while OCR is pending. Navigation clears
  the published excerpt immediately, and invalidation retires predictions conditioned on it.

## Scoped Translation and Model Budgets

- `Models/Settings/ModelContextSettings.swift` persists one task's model/destination token map;
  `SuggestionSettingsModel+Context.swift` projects active completion identity and budgets.
- `Models/LanguageLearning/LearningTranslationInput.swift` separates target/reference text from AX
  captures. `LearningLocalModelConfiguration.swift` freezes the native model URL, adapter and
  capacity together for planning/decode, without owning an allocation.
  `Support/LanguageLearning/LearningTranslationBudget.swift` plans complete targets with
  reference-only cropping; `Support/Prompting/ModelContextBudget.swift` supplies shared allocation
  limits and endpoint estimates. Their direct pure tests live under `CotabbyTests/Support/Prompting`.
- `LearningModelController` schedules native or estimated planning away from MainActor;
  `LearningLocalRuntime` counts actual vocabulary/template tokens and owns native capacity.
  `LearningTranslationService` validates the immutable plan and output before publication.
- `App/Coordinators/InlineFeatures/LearningSentencePreviewCoordinator.swift` owns the versioned
  preview, capture, cancellation and replacement transaction. The existing sentence panel/card
  presents both automatic and explicit previews; the existing selection service owns the single
  scoped write. Coordinator and native integration tests mirror those subsystems.
- `UI/Settings/Components/Controls/ModelContextSection.swift` is reused by completion/translation
  model pages; `LearningShortcutRows.swift` and `AppShortcutSection.swift` are hosted only by
  `ShortcutsPaneView`. Its transient `ShortcutRecordingState.swift` owns the single active recorder,
  keeping global/translation/app rows mutually exclusive without adding another input monitor.
  `ApplicationBundlePicker.swift` shares app selection with `AppsPaneView`.

## Settings Update Boundaries and Profiling

- `Models/Settings/SettingsAttentionModel.swift` owns the window coordinator's small, deduplicated
  warning projection. `Support/Settings/SettingsAttentionEvaluator.swift` retains the pure policy;
  the model combines incoming permission, engine/configuration and availability/failure values.
  Its direct publication tests mirror it under `CotabbyTests/Models/Settings`.
- `SettingsContainerView` observes only that projection and its `SettingsNavigationModel`.
  Destination panes observe their own dependencies; source services passed through the container
  are ordinary strong references. Repeated category selections are deduplicated while retaining
  the detail identity workaround, existing pane scaffold and search arrival behavior.
- `UI/Settings/Components/Structure/SettingsPaneScaffold.swift` owns the single Form scroll
  viewport and the cancellable search reveal. Its real-AppKit scrolling tests are under
  `CotabbyTests/UI/Settings/Components/SettingsPaneScaffoldTests.swift`, including callouts,
  initial search arrivals and subsequent searches in both scroll directions.
- `UI/Settings/Panes/LanguageLearningPaneView.swift` uses fixed translation/alignment/read-aloud/dictionary
  tabs and mounts one behavior form at a time; task configuration remains in `Panes/Engine/`. `SettingsNavigationModel` owns task tabs,
  task-scoped resource sheets, advanced expansion and search destinations without changing models.
- `Models/LanguageLearning/LearningDictionarySettings.swift` persists the enabled dictionary sources
  and lookup order as one configuration. `LearningDictionarySession` observes only this store;
  dictionary changes do not invalidate translation or autocomplete. `DictionarySettingsSection`
  reuses the language-learning Form and its searchable settings-row anchor.
- `LearningDictionarySources.swift` models stable source/book/website identities and file bookmarks.
  `Services/LanguageLearning/LearningDictionaryRouter.swift` dispatches immutable query plans to
  the lexicon, `MDictLibraryService`, `SystemDictionaryArticleService` and `OnlineDictionaryClient`.
  `Packages/MDictReader` contains the attributed, bounded MDX/MDD parser and its independent tests.
  `native/dictionary/system_dictionary.m` is the disposable private DCS helper; preparation and
  embedding scripts build it for both app architectures. `DictionaryHTMLPolicy`, `DictionaryLinkPolicy`
  and `DictionaryWebsitePolicy` own deterministic content/navigation rules. `DictionaryHTMLView`
  owns disposable WebKit rendering and scoped resource requests inside the existing card.
- `DictionaryLanguagePair.swift` separates headword and gloss capabilities and owns the curated
  website catalog. Optional metadata is backward-compatible with existing imported books/sites. Unannotated books
  remain manually selectable and join automatic lookup only after an entry language or multilingual
  capability has been explicitly recorded.
  The immutable configuration filters known entry-language mismatches and ranks gloss preferences;
  websites still require a separate explicit browser click. Original-text lookup uses the same
  dictionary session and maps exact vocabulary occurrences back into a captured reading sentence.
- `LearningDetailPanelLayout` accepts the previous frame as a preference, never as permission to
  overlap an obstacle. The panel translates it with parent movement and anticipates the bounded
  content viewport on first placement. `LearningDictionaryViewport` fixes the first measured definition's 120–300pt viewport through
  loading/source changes and reserves its attribution row, preventing transient collapse and jumps.
  Native language-candidate regression fixtures live in `native/dictionary/tests/`.
- `LearningPopupWindowRegistry` belongs to one detail-card host. The source popover reports its
  actual window through `UI/Components/LearningPopoverWindowReader`; local and global click routing
  share this weak membership when SwiftUI temporarily omits a parent link. Replacing the host
  replaces its registry. Global clicks still require the exact visible Window Server hit.
  `UI/InlineFeatures/DictionarySourceRow` owns the full-row hit target and size-neutral hover/press
  feedback; changing a source does not rebuild or reposition the dictionary panel.
- `UI/Settings/Components/Structure/SettingsAdvancedSections.swift` keeps collapsible sections as
  native Form siblings. `SettingsModelManagementSheet.swift` shares resource-window chrome while
  callers provide the existing task-owned download services and actions.
- `UI/Settings/Components/Structure/SettingsRenderDiagnostics.swift` is the opt-in body/layout
  probe, separate from reusable pane chrome. `CotabbyTests/UI/Settings/SettingsPerformanceTests.swift`
  measures the real container with isolated stores and verifies both background-update isolation
  and continued updates in the visible pane. Native profiling supplements the cold-window fixture.

## Context Computation Reuse

- `Support/Settings/ModelContextIdentityCache.swift` is a two-slot identity memo owned separately by
  completion settings and each learning profile. Explicit incoming inputs preserve Combine timing;
  budget values are still resolved from each owner's existing map. Tests mirror it in Support/Settings.
- `Support/LanguageLearning/LearningTranslationBudget.swift` returns the winning request with a
  generic measured payload. `LearningPromptTokenCache.swift` retains one exact, single-use native
  token plan for `LearningLocalRuntime`; it is separate from model sequences and KV state. Native
  operations serialize access and clear it on model reload/release. Tests mirror this responsibility
  under Support/LanguageLearning.

`native/tts/` owns the pinned llama.cpp audio helper, its protocol boundary and upstream MIT notice.
`scripts/prepare_tts_runtime.sh` builds it; `scripts/embed_tts_runtime.sh` embeds it in both app identities.
The autocomplete inference package and its revision remain separate.

## Reading Translation Sources

- `Models/LanguageLearning/LearningReadingSelection.swift` is an immutable, memory-only read
  receipt and capture contract. It deliberately has no write capability or replacement range.
- `Support/LanguageLearning/LearningReadingPolicy.swift` rejects empty or oversized selections
  before planning. The existing planner still budgets the complete target and shared style.
- `Services/LanguageLearning/LearningReadingSelectionReader.swift` owns bounded AX selection
  queries and selection notifications. It never reads a whole page or the clipboard; unavailable
  selections remain explicit errors instead of triggering a synthetic copy.
- `App/Coordinators/InlineFeatures/LearningReadingCoordinator.swift` owns reading request identity,
  cancellation, language direction and optional affordance lifetime. `InlineCommandCoordinator`
  starts/stops it; `CotabbyAppEnvironment` shares the existing models, lexicon and speech owner.
- `Services/Presentation/LearningSelectionIconPanel.swift` is only a nonactivating trigger.
  Reading results reuse `LearningSentencePanel` and its existing card/details with replacement
  disabled. Reading and writing yield presentation to each other without changing card structure.
- `PerAppShortcutOverride` persists explicit selection-shortcut permission and independent icon
  policy. App management edits permission; `LearningShortcutRows` remains the single binding
  editor. Unknown apps pass the selection chord through to the host.

- `Services/LanguageLearning/LearningReadingSourceReader.swift` adapts explicit selection, pointer
  and screen-region sources into the same immutable receipt. Pointer lookup tries bounded AX and
  falls back to local Vision word boxes; region capture requires Screen Recording independently
  of AX. Images stay within acquisition and never enter a model request or a persisted artifact.
- `Services/Presentation/LearningRegionSelectionPanel.swift` owns disposable nonactivating panels
  and one cancellable region-selection continuation. It has no translation or screenshot behavior.
- `Support/LanguageLearning/LearningReadingTextPolicy.swift` owns display-local crop geometry,
  UTF-16 word targeting and conservative OCR reading order, including simple columns. Reading uses
  all recognized lines, never autocomplete's confidence/chrome filters or capped context string.
- `WindowScreenshotService.captureRegion` matches the screen's display ID before computing its
  local crop; no editable focus or automatic screen-context preference is needed. `ScreenTextExtractor`
  optionally returns exact Vision word boxes only for explicit pointer queries, and cancels its own
  native request when its task is retired. Existing autocomplete extraction defaults are preserved.
- Each source has an independent default-off feature switch, explicit App permission, and central
  shortcut. Legacy App rows gain no pointer/screenshot permission. OCR metrics use their own source
  and the same trace ID as translation; persisted records contain timings and status, not text/images.
- SelectedTextKit was evaluated, not integrated: its AX-only path duplicates the existing reader,
  while automatic fallback may copy text. Lingrove retains its bounded AX receipt/currentness checks.

## Vocabulary notebook

`Models/Vocabulary` owns durable entries, examples with UTF-16 spans, dictionary attribution,
and the versioned export schema. `Support/Vocabulary` turns immutable card snapshots into
captures and owns deduplication, bounded context extraction and search rules.
`Services/Vocabulary` owns the lazy UI store and serialized atomic local archive; no notebook
operation starts model inference. `UI/Vocabulary` owns browsing and explicit editing drafts.
`VocabularyWindowController` provides one normal library window; floating cards retain their
existing nonactivating lifetime. The shared fish-tail button lives in `UI/Components`.

The environment constructs one store for both writing and reading cards, isolates the XCTest
host from real user data, and keeps Dev/production archives in separate support directories.
Vocabulary shortcuts are edited only in Shortcuts. Their unset defaults do not claim host keys.

## Contextual AI explanation

`Models/LanguageLearning/LearningExplanationModels.swift` freezes the chosen text and exact
occurrence spans; it also defines the validated two-part explanation and durable record.
`Support/LanguageLearning/LearningExplanationPolicy.swift` builds target-preserving prompts,
bounds only surrounding reference context, excludes translation specialists and validates results.
`Services/LanguageLearning/LearningExplanationService.swift` borrows the independent explanation
controller from `LearningModelCollection`, shares request telemetry and bounds its completed cache.
Each card/window owns a lightweight `LearningExplanationSession` for cancellation and stale replies;
all generation is explicit, with no typing observer or background explanation queue.

`UI/InlineFeatures/LearningExplanationView.swift` presents the same result/actions in dictionary,
sentence and notebook surfaces. `UI/Vocabulary/VocabularyExplanationSection.swift` chooses an
existing captured usage. The archive retains annotations separately from user meanings and notes;
only explicit adoption writes a meaning to a precise entry/example and language slot. Editing or
removing a usage prunes its obsolete explanation context. Tests mirror these boundaries under
Support/LanguageLearning, Services/LanguageLearning and Services/Vocabulary.
