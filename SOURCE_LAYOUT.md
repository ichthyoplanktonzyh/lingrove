# Lingrove Source Layout

This document is the canonical placement map for production and test source files. It complements
`ARCHITECTURE.md`, which explains runtime ownership and data flow.

Swift folders do not create namespaces. Every Swift file discovered under `Lingrove/` still compiles
into the application module, and every file under `LingroveTests/` compiles into the test module.
Folders exist so a maintainer can predict where a responsibility lives before searching.

## Placement Rules

1. Choose the top-level architectural boundary first: `App`, `UI`, `Services`, `Models`, or
   `Support`.
2. Choose the product subsystem next, such as `Suggestion`, `Focus`, `Runtime`, or `Settings`.
3. Keep a small cohesive subsystem flat.
4. Add a child folder only when at least two files form a stable responsibility with a predictable
   name. Do not create one-file folders merely to shorten a file list.
5. Put a direct unit test under the corresponding `LingroveTests/` responsibility. Cross-cutting
   coordinator tests may remain grouped by the coordinator they exercise.
6. Folder moves must not change Swift access control, runtime ownership, or target membership.
   XcodeGen discovers the new paths; regenerate `Lingrove.xcodeproj` after moving files.

## Production Tree

~~~text
Lingrove/
├── App/
│   ├── Core/                         process entry, composition root, lifecycle
│   │   └── ApplicationRelauncher.swift safe relaunch after interface localization changes
│   └── Coordinators/
│       ├── InlineFeatures/           emoji/macro capture arbitration and explicit expression sessions
│       ├── Suggestion/               autocomplete interaction state machine
│       ├── SettingsCoordinator.swift
│       └── WelcomeCoordinator.swift
├── Models/
│   ├── CLI/                          app/client wire requests, batch input, replies and stable errors
│   ├── ProductIdentity.swift         localized brand names and independent project destinations
│   ├── Context/                      bounded context and visual-context values
│   ├── Emoji/                        picker and usage values
│   ├── ExpressionAssist/             bounded requests, candidate contracts and interaction preferences
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
│   ├── CLI/                          passive mailbox consumption and user-level executable installation
│   ├── Context/                      live clipboard acquisition
│   ├── ExpressionAssist/             shared general-model generation and verified editor adapter
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
│   └── Visual/                       capture, OCR admission/helper lifetime, and visual-context sessions
├── Support/
│   ├── Accessibility/                pure AX and secure-surface policies
│   ├── Context/                      sanitization, relevance, and OCR hygiene
│   ├── Emoji/
│   │   ├── Catalog/                  searchable catalog and synonyms
│   │   ├── Interaction/              query, trigger, picker, and variant rules
│   │   └── Ranking/                  recency and popularity rules
│   ├── ExpressionAssist/             literal triggers, bounded prompt/JSON validation and input placement
│   ├── Focus/
│   │   ├── Applications/             app, browser, domain, and terminal classification
│   │   └── Capability/               supported-field capability resolution
│   ├── History/                      history retrieval, phrase prediction, scrubbing, import
│   ├── Input/                        composition, key-label, and selection helpers
│   ├── Vocabulary/                   capture identity, graph projection, local example extraction, merge and search rules
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
    ├── Previews/                     Debug-only Canvas hosts and isolated card fixtures; renders the real InlineFeatures views
    ├── InlineFeatures/               emoji picker, macro reference and native expression candidate rows
    ├── Components/CurrentShortcutRow.swift read-only shortcut labels shared by help and setup
    ├── MenuBar/                      shared status, completion/learning quick controls, bounded popover content and precise settings routes
    ├── Onboarding/
    │   ├── OnboardingDemoCard.swift   shared completion/learning demo chrome with bounded content
    │   ├── LearningFeatureShowcase.swift shared area picker; legacy Welcome illustrations
    │   ├── HomeLearning*.swift       shared Home/guide scenario player; real cards and sessions using fixed local examples
    │   ├── ProductFeatureExample.swift explicit shared examples for the guide and welcome
    │   └── Welcome/                  resumable setup with shared task forms, language/shortcut preferences and configuration status
    ├── Overlays/                     SwiftUI overlay content
    └── Settings/
        ├── ProductUsageGuideView.swift window-owned scenario guide, live shortcut labels and explicit shared examples
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

`LingroveTests/` mirrors the production responsibility after removing the leading `Lingrove/`. For
example:

~~~text
Lingrove/Support/Suggestion/Output/SuggestionTextNormalizer.swift
LingroveTests/Support/Suggestion/Output/SuggestionTextNormalizerTests.swift

Lingrove/Services/Runtime/Llama/LlamaSuggestionEngine.swift
LingroveTests/Services/Runtime/Llama/LlamaSuggestionEngineStreamingTests.swift

Lingrove/App/Coordinators/Suggestion/SuggestionCoordinator.swift
LingroveTests/App/Coordinators/Suggestion/SuggestionCoordinatorPredictionTests.swift
~~~

Tests that exercise several production values may stay at the nearest shared subsystem root. Evals
remain under `LingroveTests/Evals`, and shared fixtures remain under `LingroveTests/TestSupport`.

## Per-App Settings

- `Models/Settings/PerAppBehavior.swift` describes optional app overrides. The existing
  `PerAppShortcutOverride` persistence record carries them alongside shortcuts, preserving old
  settings data. `SuggestionSettingsModel` publishes the UI state and projects immutable behavior
  maps into `SuggestionSettingsSnapshot`.
- `Support/Settings/PerAppSettingsResolver.swift` resolves inherited mid-line and typo behavior;
  `AppSettingsList.swift` merges configured, historical, excluded and running applications without
  owning AppKit state. Their direct tests live under `LingroveTests/Support/Settings/`.
- `UI/Settings/Panes/AppsPaneView.swift` presents that list. `Panes/Apps/AppSettingsDetailView.swift`
  edits one app through the environment-owned settings and history stores;
  shortcut summaries link to the central Shortcuts pane. `PerAppShortcutRowsView.swift` is hosted
  there through `Components/Controls/AppShortcutSection.swift` and reuses the shared recorder. These views
  use the existing settings scaffold, rows and callouts. Opt-in rendering checks live under
  `LingroveTests/UI/Settings/`.
- `SuggestionRequestFactory` carries app instructions separately from global notes. Both prompt
  renderers consume the same immutable request value, and the base renderer gives app notes their
  own bounded section. `LingroveTests/Support/Settings/PerAppInstructionsTests.swift` checks that
  boundary and default-prompt compatibility.
- `TypingHistoryStore` owns app-scoped encrypted deletion and the existing full-history lifecycle.
  Its generation and write-sequence guards invalidate older imports and queries before publishing
  a successful delete. `LingroveTests/Services/History/PerAppHistoryDeletionTests.swift` covers races,
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
  limits and endpoint estimates. Their direct pure tests live under `LingroveTests/Support/Prompting`.
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

- `LlamaRuntimeManager.resetPromptCache` is an async native-maintenance barrier. Its ordered
  detached tasks keep load/decode lock waits off MainActor; cancellation of a superseded UI caller
  cannot let a later reset overtake earlier work. `LlamaSuggestionEngine` clears Swift reuse hints
  immediately and awaits this barrier before returning. Native entry points also recheck pending
  maintenance after model preparation, which can suspend while a newer reset is queued.
  `LlamaRuntimeMaintenanceTests` uses a
  blocked fake native operation to check UI-actor progress and cancellation ordering without a GGUF.
- `Models/Settings/SettingsAttentionModel.swift` owns the window coordinator's small, deduplicated
  warning projection. `Support/Settings/SettingsAttentionEvaluator.swift` retains the pure policy;
  the model combines incoming permission, engine/configuration and availability/failure values.
  Its direct publication tests mirror it under `LingroveTests/Models/Settings`.
- `SettingsContainerView` observes only that projection and its `SettingsNavigationModel`.
  Destination panes observe their own dependencies; source services passed through the container
  are ordinary strong references. Repeated category selections are deduplicated while retaining
  the detail identity workaround, existing pane scaffold and search arrival behavior.
- `UI/Settings/Components/Structure/SettingsPaneScaffold.swift` owns the single Form scroll
  viewport and the cancellable search reveal. Its real-AppKit scrolling tests are under
  `LingroveTests/UI/Settings/Components/SettingsPaneScaffoldTests.swift`, including callouts,
  initial search arrivals and subsequent searches in both scroll directions.
- `UI/Settings/Panes/LanguageLearningPaneView.swift` uses fixed translation/explanation/read-aloud/dictionary
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
  probe, separate from reusable pane chrome. `LingroveTests/UI/Settings/SettingsPerformanceTests.swift`
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
  starts/stops it; `LingroveAppEnvironment` shares the existing models, lexicon and speech owner.
- `Services/Presentation/LearningSelectionIconPanel.swift` is only a nonactivating trigger.
  Reading results reuse `LearningSentencePanel` and its existing card/details with replacement
  disabled. Reading and writing yield presentation to each other without changing card structure.
- `PerAppShortcutOverride` persists explicit selection-shortcut permission and independent icon
  policy. App management edits permission; `LearningShortcutRows` remains the single binding
  editor. Unknown apps pass the selection chord through to the host.

- `Services/LanguageLearning/LearningReadingSourceReader.swift` adapts explicit selection, pointer
  and screen-region sources into the same immutable receipt. Pointer lookup prefers local Vision
  and retains bounded AX fallback; region capture requires Screen Recording independently
  of AX. Images stay within acquisition and never enter a model request or a persisted artifact.
- `Services/Presentation/LearningRegionSelectionPanel.swift` owns disposable nonactivating panels
  and one cancellable region-selection continuation. It has no translation or screenshot behavior.
- `Support/LanguageLearning/LearningReadingTextPolicy.swift` owns display-local crop geometry,
  UTF-16 word targeting and conservative OCR reading order, including simple columns. Reading uses
  all recognized lines, never autocomplete's confidence/chrome filters or capped context string.
- `WindowScreenshotService.captureRegion` matches the screen's display ID before computing its
  local crop; no editable focus or automatic screen-context preference is needed. `ScreenTextExtractor`
  optionally returns exact Vision word boxes only for explicit pointer queries. It borrows the
  app-owned `OCRRuntime`, shared with autocomplete context; retiring a caller cancels its result
  without entering Vision's native cancellation path. Existing extraction defaults are preserved.
- `Models/Context/OCRWorkerProtocol.swift` is compiled by the app and `native/ocr/main.swift`;
  it owns bounded, versioned local image/result frames. `Services/Visual/OCRRuntime.swift` owns
  one native transport thread, one active child operation, latest-only pending images, priority,
  cancellation and backoff. `OCRWorkerProcess.swift` exclusively owns child/pipes on that thread.
  Tests mirror this under `LingroveTests/Services/Visual/`; helper faults never ship in the app.
- `Services/Visual/DebugScreenshotWriter.swift` owns optional sampled PNG/OCR archives. Its single
  background native thread bounds pending captures and keeps encoding, writing and retention off
  MainActor and the shared executor. The environment owns shutdown; the generator only submits
  fresh captures, so a cache hit does not repeat diagnostic I/O. Tests mirror this under Visual.
- `Support/Context/VisualContextActivity.swift` owns the monotonic activity window for background
  refresh. New fields and eligible keyboard input renew it; AX polls cannot. The visual coordinator
  owns timers and expiry while the suggestion input boundary supplies actual editing activity.
- Each source has an independent default-off feature switch, explicit App permission, and central
  shortcut. Legacy App rows gain no pointer/screenshot permission. OCR metrics use their own source
  and the same trace ID as translation; persisted records contain timings and status, not text/images.
- SelectedTextKit was evaluated, not integrated: its AX-only path duplicates the existing reader,
  while automatic fallback may copy text. Lingrove retains its bounded AX receipt/currentness checks.

## Vocabulary notebook

`Models/Vocabulary` owns durable expressions, stable senses, examples with UTF-16 spans, meaning ownership,
and versioned portable snapshots. Dictionary bodies are live queries and are never archived. `Support/Vocabulary` turns immutable card snapshots into
captures and owns deduplication, bounded context extraction and search rules.
`Services/Vocabulary` owns the lazy UI store and serialized atomic local archive.
`VocabularySensePolicy` owns exact-occurrence membership, explicit merge/move rules and retired-ID aliases;
no generated wording is used as an identity. `VocabularyNotebookSession` belongs to the library window, retains a lightweight explanation
session per usage of the selected sense, and cancels them on navigation/closure. Browsing only restores records;
generation remains explicit in the notebook. `UI/Vocabulary` owns browsing and editing drafts.
`VocabularyDictionarySection` queries only while expanded, sharing the provider/settings,
`LearningDictionarySourcePicker`, `LearningDictionaryDefinitionView`, and attribution with cards.
`VocabularyWindowController` provides one normal library window and favorite navigation to an exact sense; floating cards retain their
existing nonactivating lifetime. The shared fish-tail button lives in `UI/Components`.

The environment constructs one store for both writing and reading cards, isolates the XCTest
host from real user data, and keeps Dev/production archives in separate support directories.
The live file is `Vocabulary/notebook.sqlite`, initialized as a fresh library. Retired JSON
archives are neither read nor migrated nor deleted. SQLite's `application_id` and `user_version`
identify its independent schema; portable backups/exports retain their existing JSON formats.
Vocabulary shortcuts are edited only in Shortcuts. Their unset defaults do not claim host keys.

`VocabularyDatabaseRecord` and `VocabularyDatabaseProjection` split expressions, senses, usages,
AI records, content blocks, review cards/bindings and templates into owned rows. JSON payloads
contain a single entity's scalar/leaf values, with children stripped; foreign keys and order live
in SQL columns. `VocabularySQLiteConnection` confines C pointers, copied bindings and private
regular-file identity checks. The archive-owned `VocabularySQLiteDatabase` initializes a schema
before exclusive publication, uses WAL/FULL transactions, rejects unsupported or damaged files,
and encodes/upserts changed rows only. `VocabularySQLiteFileLock` extends writer serialization
across image staging/GC and keeps backup/export media reads consistent between app instances.
A durable revision rejects stale commits. Domain graph
validation and the existing UI snapshot model remain in place; search still filters those values
in memory and is not claimed to have become an indexed/paged database search in this change.

`VocabularyContentModels` adds optional, ordered text/image blocks to a sense. The existing
`meaning` remains its compact label; user blocks never become AI usage records. `VocabularyContentPolicy`
validates sizes and serializes only app-generated formatting. `VocabularyImageStorage` is owned by
the archive actor, normalizes imports to bounded PNGs, and keeps hash-named files in
`notebook.sqlite.media/`. Editor drafts hold imported bytes in memory; Save writes referenced media
before the SQL commit, rolls back new files on failure, and retires unreferenced images
only after commit. `VocabularyContentEditor` and `VocabularyContentView` share the native editor
and read-only presentation; no inference or new provider is involved.

`VocabularyArchive+Media` owns portable `.lingrove` backups (versioned JSON envelope containing the
document and referenced image bytes) and explicit replacement restore. JSON data export contains
references only. Restore validates the entire package, preserves sense/Anki identities, and can
repair corrupt media using verified backup bytes. `ReviewPlan.includeSenseContent` is optional:
existing plans retain their previous fields, while new plans include sense explanations. Generated
image markup travels in the mapped Meaning/answer field, only after `AnkiReviewSession+Images`
uploads media to the verified Anki profile. The preview uses that same markup and local resources.
Legacy preset gap fronts require an explicit template upgrade before including sense content.
Arbitrary HTML and animated blocks are deferred.

`VocabularyExportModels` defines the sheet's scope/options and a versioned portable projection.
`VocabularyExportPolicy` selects exact sense IDs and separates primary values from language
variants; `VocabularyExportFormatter` renders TXT learning notes/expression lists, CSV usage rows,
and structured JSON. `VocabularyExportZIP` wraps optional hash-named PNGs in a bounded stored ZIP.
`VocabularyArchive+Export` freezes metadata and media bytes on the archive actor, then atomically
writes that prepared package. The window-owned `VocabularyExportSession` discards stale previews
and owns cancellation; `VocabularyExportSheet` reuses a native grouped form and save panel.
Export opens from the notebook toolbar, batch selection or a sense's context menu. It never
queries a model, dictionary, TTS or Anki; full `.lingrove` backup/restore remains a separate path.

## Local vocabulary CLI

`LingroveCLI/` is a separate executable target, embedded by `scripts/embed_cli.sh` in both app
bundles. `Models/CLI` and `Support/CLI` compile into both targets: the versioned wire contract,
strict batch shape/count validation, deterministic argument parsing and bounded atomic file IO.
The CLI reads explicitly supplied image paths, transports bytes, and lets its containing bundle
choose Dev/production identity. It never opens SQLite or calls an AI/Anki provider.

`LingroveAppEnvironment` owns one `CLIMailboxServer` actor and one `CLIInstallationModel`.
The server holds an exclusive lifetime lease on a private app-specific mailbox; a passive
directory source wakes its serial drain. `VocabularyStore.executeCLI` forwards to the existing
archive actor and applies acknowledged snapshots so open windows refresh. `VocabularyCLIPlan`
owns pure additive/update planning with stable IDs, explicit ownership and revision conflicts;
`VocabularyCLIReadBudget` bounds whole-entry response construction before JSON encoding.

`VocabularyArchive+CLI` owns query projection, image preparation, dry runs and replay lookup.
SQLite schema 2 adds `cli_receipts`; upgrading schema 1 preserves the accepted SQLite content,
while retired JSON files are still ignored. A content commit, revision and receipt are one SQL
transaction, with the existing media staging/rollback lock. CLI receipts are operational state,
excluded from notebook backups/exports. `CLISettingsSection` reuses General's settings rows and
the searchable `commandLineTools` entry, installing user-level `lingrove`/`lingrove-dev` symlinks
without overwriting unrelated commands or editing shell configuration. `CLI.md` is the agent-facing
usage contract; tests under `Services/CLI` launch the actual bundled executable against an isolated
mailbox/store/SQLite notebook and never send requests to a real user library.

## Contextual AI explanation

`Models/LanguageLearning/LearningExplanationModels.swift` freezes the chosen text and exact
occurrence spans; it also defines the validated two-part explanation and durable record.
`Support/LanguageLearning/LearningExplanationPolicy.swift` builds target-preserving prompts,
bounds only surrounding reference context, excludes translation specialists and validates results.
The input marks complete-sentence, fragment or absent context; clipped references downgrade to a
fragment. Local occurrence receipts separate equal sentences saved with different translations and
are never sent to the model. The prompt permits uncertainty and general senses without context.
`Services/LanguageLearning/LearningExplanationService.swift` borrows the independent explanation
controller from `LearningModelCollection`, shares request telemetry and bounds its completed cache.
Each card or saved usage owns a lightweight `LearningExplanationSession` for cancellation and stale
replies. An explicit non-sentence lookup opens the contextual page and starts one explanation when
AI is configured; otherwise it opens the dictionary directly. Tabs/source changes never restart stopped AI work. Whole-sentence
explanations and notebook generation remain explicit, with no typing observer or background queue.

`UI/InlineFeatures/LearningExplanationView.swift` presents the same result/actions in dictionary,
sentence and notebook surfaces. The contextual presentation leads with the sense and folds details.
`UI/Vocabulary/VocabularyExplanationSection.swift` places it beside its saved example. Completed
results fill/refresh captured or AI draft meanings; user-edited meanings require explicit
replacement. The archive retains explanations separately from meanings and notes. Collection before
or after generation produces the same usage, without persisting dictionary snapshots. Editing or
removing a usage prunes its obsolete explanation context. Tests mirror these boundaries under
Support/LanguageLearning, Services/LanguageLearning and Services/Vocabulary.

## Deferred chunk alignment

The complete chunk-alignment implementation, settings, exact-quote parser, colored correspondence
UI and model evaluation harnesses are preserved at `codex/chunk-alignment-experiment-20261020`
(commit `7a999e14`). The current product has no alignment controller, request stage or settings route.
Offline lexical recognition, contextual explanation and live dictionary lookup remain independent.
`UI/InlineFeatures/LearningTextLayout.swift` owns the dictionary component-word flow layout and
shared card measurement preference formerly colocated with the removed alignment chips.
Historical performance records still decode their `analysis` source, which is excluded from the
selectable task list. Existing alignment preferences and downloaded files are not deleted or read.

## Anki review

`Models/Review` owns review-only plans, durable pending/confirmed Anki bindings, connection
snapshots and typed wire values. A sense owns independent `reviewCards`; the optional legacy `review` records remain readable
without migration. The vocabulary archive remains the single atomic writer.
`Support/Review` prepares cards from exact usage spans, escapes text for HTML, maps logical fields,
compares last-synced/local/remote values and defines the versioned preset note template.

`Services/Review/AnkiConnectClient.swift` is the loopback-only, bounded, no-redirect HTTP boundary.
`AnkiReviewController` is constructed once by the environment and shared by Settings and Vocabulary;
it owns operation exclusion and connection metadata, without startup probes or background sync.
Each `AnkiReviewSession` belongs to one preparation sheet. It persists creation identity before a
write, recovers uncertain acknowledgements by that identity, revalidates the active profile/source,
and records successful synchronization only after rereading the remote fields. Anki card IDs and
scheduling remain under Anki's ownership. Removing existing card types is managed in Anki.

`UI/Vocabulary/VocabularyReviewSection.swift` lists the sense's independent cards and status;
`VocabularyReviewSheet.swift` edits review-only content and displays previews/conflict choices.
`UI/Settings/Panes/LearningReviewSettingsSection.swift` reuses the grouped settings form under
Language Learning → Review, including searchable reusable card templates. Existing notebooks,
dictionary lookups, explanation generation and favorites never trigger an Anki write themselves.

### Review audio, template and queue boundaries

`ReviewOperationScope` freezes the Anki connection, profile and selected configuration for one
explicit operation, including defaults used by unprepared rows. Saving a successful choice only
updates preferences that have not changed in another window. Batch rows carry `VocabularySelection` IDs and resolve merged aliases before
work. `AnkiReviewBatchSession` owns one serial cancellable queue; single-sense preparation continues
through `AnkiReviewSession`, so receipt recovery and field conflicts have one implementation.
`VocabularyReviewBatchSheet` owns selection/preparation navigation and per-item results; cancelling
preparation preserves a synchronized row, and reopening a queue recognizes already-saved receipts.

`ReviewAudioPreparation` borrows `SpeechExporting` from the app-owned `LearningSpeechController`.
The controller reuses its existing generator for local/endpoint audio and lazily owns a silent
`SystemSpeechAudioExporter` for Apple voices. `SpeechExportBuffer` owns bounded request bytes;
`SpeechExportPolicy` validates WAV/MP3 and packages native/system audio as 16-bit PCM WAV. Export
uses normal recording speed; the existing playback-rate preference continues to affect playback,
not the stored recording. No temporary WAV files or audio bytes enter the notebook. A sheet owns
its prepared audio only until close; Anki owns uploaded media. Receipts contain scoped fingerprints
and opaque hash filenames, and reuse checks that Anki still has the file. Voice/language is frozen
per action and all generation is opt-in; collection, browsing and typing start no export work.

`AnkiNoteTemplate` supplies both exported templates and the HTML preview. The preview borrows
`DictionaryHTMLView`'s existing no-script, no-network renderer. Gap questions expose neither a
meaning hint nor answer audio. The two template names and ordinals remain stable during an explicit
upgrade; customized templates are never overwritten and customized CSS is retained. Navigation
opens Anki's deck overview, using a linked note's current deck, and leaves scheduling to Anki.

### Flexible review cards

`ReviewLayout` models independent cards under `VocabularySense.reviewCards` and reusable layouts
under `VocabularyDocument.reviewTemplates`. Each card uses its plan UUID for remote identity;
legacy review records are not migrated into cards. `ReviewLayoutPolicy` resolves ordered typed
sources into the same safe HTML for preview and Anki. References follow stable usage/block IDs;
card-only rich content belongs to the card. Missing sources block sending without discarding drafts.

`VocabularyArchive+ReviewCards` keeps per-card CAS and template transactions inside the notebook
actor. All accepted layouts, including retained plans, participate in backup and media garbage
collection. `VocabularyReviewLayoutEditor` reuses the native rich-content editor and Front/Back
segmented selection. Templates copy layout roles and custom prompts; applying one binds source
slots to the destination sense and never rewrites existing cards. The generic Anki model has one
card per note and three fields: LingroveID, Front, Back. Sends verify its live templates, destination,
source and media, while the shared session retains conflict handling and lost-ack recovery.

## Menu Bar Quick Controls

`MenuBarView` restores the completion panel from before the learning-menu change: direct native
switches, eight-point spacing, its original status text, natural height and original footer.
A persisted task picker is the only navigation addition. Pause/recovery children are shared through
a layout-free ViewBuilder property. `MenuBarLearningControls` observes the shared language settings
and follows that original native-toggle and `MenuBarPickerRow` design. Its speech disclosure borrows
the same app-owned speaker used by cards and Settings. `MenuBarContentViewport` bounds only learning
content; review is an action on that page, while the original vocabulary/settings footer stays visible. Typed menu destinations pass through
`SettingsNavigationModel` and the existing `SettingsCoordinator`, after popover dismissal.
Learning rows read saved model profiles without additional model discovery, voice enumeration or
generation; the existing menu presentation refresh still updates completion model availability.
`AppDelegate` retains one `MenuBarController` (Services/Presentation), which owns NSStatusItem,
NSPopover and a stable NSHostingController child. SwiftUI no longer owns a MenuBarExtra scene.
`MenuBarPresentationModel` keeps selected/displayed page state and cancels superseded fades;
measured layouts carry their page identity so outgoing reports cannot resize the new page.
Only the menu controller changes `popover.contentSize`. Its parent viewport clips the top-anchored
hosting child while native resizing occurs, keeping controls at their natural size. The native
popover owns background, border, placement, shadow and outside-click dismissal. Header/picker
stay mounted; only the page body fades. Reduce Motion disables both fades and native animation.
A dedicated completion toggle calls the existing completion setting without disabling learning.
Late geometry is rejected during closing, including while AppKit is still animating dismissal.
The existing status label and settings bindings remain shared; status visibility, opening refresh,
settings/vocabulary routing and lifecycle cleanup now pass through the native controller.

## Vocabulary Graph

- `Models/Vocabulary/VocabularyGraphModels.swift`: immutable headword/sense graph, validated appearance/force settings and camera math.
- `Support/Vocabulary/VocabularyGraphProjection.swift`: filtered notebook to explicit ownership edges; no inferred semantic links.
- `Services/Vocabulary/VocabularyGraphLayoutWorker.swift`: window-owned actor confining the Grape simulation and rejecting stale epochs.
- `UI/Vocabulary/VocabularyGraphPresentation.swift`: window browsing/preferences lifetime, independent of SQLite content.
- `UI/Vocabulary/VocabularyGraphView.swift`: native controls/settings and the canvas adapter.
- `UI/Vocabulary/VocabularyGraphCanvasView.swift`: AppKit drawing, input, accessibility and a bounded animation task that ends when cool.
- `Packages/LingroveGraphLayout`: unchanged MIT-licensed Grape 1.1.0 ForceSimulation sources and a small package-local buffer adapter.

## Expression Assistance

`ExpressionAssistCoordinator` owns one invocation, its saved editor capture, and the latest query
revision. The app environment owns it and the two native input/candidate windows for process
lifetime. `ExpressionAssistPanelController` uses a real `NSTextView` for composition; its quiet
sentence-end input reuses ghost font/baseline helpers and its non-key result window owns candidate
interaction. Input uses explicit application activation and acknowledgment rather than treating an
inactive nonactivating panel's `isKeyWindow` flag as proof of keyboard delivery. Before activation,
the input takes both main and key roles so the system does not also raise a previously opened
Settings or Notebook window; readiness acknowledges both roles and the native text responder. Explicit acceptance
or cancellation returns the host; outside clicks never restore it. `ExpressionAssistFocusPolicy`
permits read-only host validation during that owned round trip; writes require restored host focus.
`ExpressionAssistLayout` keeps screen placement deterministic. The app supplies a
session-lifetime completion hold, so polling, OCR callbacks and prepared completions cannot reopen
normal writing UI during expression input; writing translation observes the same active session.
`FocusTrackingModel.captureHoldReason` forwards the editing-only hold to `FocusTracker` before any
AX call, publishing a blocked snapshot rather than retaining a stale host snapshot. Commit releases
that hold before exact host recapture. The panel deduplicates native text/composition notifications,
coalesces layout, and rebuilds candidate views only when visible presentation state changes.

`ExpressionAssistService` receives only a bounded value request. `LearningModelCollection` injects
the existing explanation controller, so this feature has no extra model profile or native runtime.
The controller cancels and drains old work before beginning another instruction request; the
explanation service and expression service retain separate prompts, parsing, sessions and metrics.

`ExpressionAssistEditor` retains the original capture while the input panel is key. On confirmation
it rechecks the original app, AX element, metadata, full value and selection, then borrows
`LearningSelectionReplacement` for one scoped write. Returning from input requires two agreeing
receipts in the restored focus session, including shared write-preflight reads; bounded read-only
retries tolerate activation/AX settling without retrying an editor mutation. `EditorTextRangePolicy` validates explicit
marker/selection/empty caret ranges without changing translation's sentence-scope policy. Tests
mirror each boundary under `Support/ExpressionAssist`, `Models/ExpressionAssist`,
`App/Coordinators/InlineFeatures` and `Services/LanguageLearning`.


## Task-Specific Local Model Selection

`Models/Runtime/LocalModelDescriptor.swift` owns immutable product aliases and curated task
identities. Download catalogs retain their original filenames, URLs and checksums; UI labels are
never persistence keys. `Support/Runtime/LocalModelTaskPolicy.swift` is the pure admission rule
shared by candidate discovery and execution preflight, including auxiliary speech resources.

`Services/ModelManagement/LocalModelTaskAssignments.swift` is a MainActor UserDefaults adapter,
not another runtime or model store. Existing saved manual/battery/AC profiles and explicit
import/download/assignment actions record custom-model intent. Directory discovery alone does
not assign a file to every task. It also records successful download provenance independently
of the catalog's expected source. Controllers and the existing download manager borrow this
small adapter, so model files continue to share one storage location.

`LearningModelController`, `LlamaRuntimeManager` and `LearningSpeechController` publish only
candidates admitted for their own task. Known incompatible saved selections remain durable and
visible, while preflight rejects them before native preparation. Explanation additionally awaits
GGUF template metadata to reject renamed translation specialists. Every yielding preflight
rechecks cancellation, settings identity and eligibility before starting work. The composition
root refreshes completion candidates after restoring old power profiles, before subscribing to
power-source changes.

`UI/Settings/ModelManagement/LocalModelDetailsView.swift` owns the optional technical disclosure
and the shared unavailable-selection label. `UnassignedLocalModelsSection.swift` observes the
existing manager's cached installed list and exposes explicit task assignment, including files
from enabled external model folders. Neither view scans files, loads metadata or owns services.
Tests mirror these boundaries under Models/Runtime, Support/Runtime, Services/LanguageLearning
and UI/Settings; offscreen UI captures are written only under the ignored build directory.


## Vocabulary Entry Creation And Word-List Import

`Models/Vocabulary/VocabularyEntryInput.swift` defines unsaved user input, bounded source rows,
column mappings, previews and acknowledged counts. Inputs have no durable IDs. The pure
`Support/Vocabulary/VocabularyWordListPolicy.swift` parses CSV/TXT and applies explicit mappings;
its transient CSV reader owns quoting/newline state separately from field interpretation.
`VocabularyEntryInputPolicy.swift` normalizes inputs, groups existing headword identities and
plans append-only changes. Exact content is skipped; distinct content becomes a new sense.
Primary, preserved standalone and merged meanings participate in duplicate recognition.

`Services/Vocabulary/VocabularyArchive+EntryImport.swift` performs bounded, permission-scoped
file reads on the existing archive actor. Preview is read-only. Confirmation holds the existing
SQLite write lock across the latest snapshot, re-planning and one atomic commit. The app-owned
`VocabularyStore` publishes only acknowledged results. `VocabularyWordListImportSession` lives
for one sheet, cancels old previews immediately when mappings/defaults change, and never retains
an obsolete document to commit later.

`UI/Vocabulary/VocabularyEntryCreationSheet.swift` owns a draft until Save. Its annotation-language
picker is shared with the import sheet. `VocabularyWordListImportSheet.swift` owns the preview
session and displays mappings, defaults, counts and a bounded table. The notebook owns sheet/file
selection state and reveals acknowledged sense IDs after clearing filters. Its empty state and
toolbar expose both entry creation and word-list import; whole-notebook restore remains separate.

A new optional `VocabularySense.createdWithoutContext` flag enables general explanations for
manual/imported senses without claiming the unique legacy favorite slot. Their existing
`LearningExplanationInput.occurrenceIdentity` carries a local `sense:<UUID>` receipt, which is
excluded from prompts. Saved lookup, cache identity and the existing fresh-result persistence
callback therefore resolve one sense. Explicit merge rebinds only known local receipts while
preserving record IDs, text, results and the legacy nil-receipt favorite behavior. No additional
runtime, provider request or automatic model generation is introduced by creation or import.


## CSV Example Import

`VocabularyEntryInput` carries optional example sentence/translation text through the same
bounded mapping, preview and commit flow. `VocabularyWordListPolicy` distinguishes the existing
word-translation header alias from sentence translation when an example column is supplied.
A translation with no sentence is rejected with its physical source line.

`Support/Vocabulary/VocabularyImportedExamplePolicy.swift` owns pure usage append/translation
merge rules. `VocabularyEntryInputPolicy.EntryIndex` caches per-headword sense keys and usage
locations for one plan, avoiding a repeated scan for each CSV row. Explicit, unambiguous core
meanings may group examples; new unclassified contexts retain independent sense identities.
Existing usage ownership never changes through import. Different translations become variants,
and unknown translation-language provenance stays unknown. Full sentence cells remain intact;
existing Unicode-safe reconciliation finds highlight spans where literal matches are available.

`VocabularyEntryImportResult.hasChanges` includes example/translation changes, so preview,
confirmation gating and the archive's transaction guard do not discard an example-only batch.
The existing store and archive remain the sole UI publication and disk transaction boundaries;
no additional model or dictionary work is introduced. Regression tests cover sentence ownership,
translation preservation, replay, stale preview, rollback, Unicode and reopen under
`Services/Vocabulary/VocabularyExampleImportTests.swift`.

## Staged Contextual Lookup

`Models/LanguageLearning/LearningLookupModels.swift` freezes an exact occurrence, its sentence
translation language and optional existing translation. The memory-only basic record owns one
meaning/translation pair; durable `LearningExplanationRecord` continues to require complete details.
`Support/LanguageLearning/LearningLookupPolicy.swift` bounds and validates the two model tasks.
The first returns only `meaning` and `sentence_translation`; details receive that accepted pair and
return only `explanation`. Exact UTF-16 occurrence ranges distinguish repeated words. An oversized
context fails whole rather than translating an excerpt different from the displayed sentence.

The app-owned `LearningExplanationService` borrows the existing general-model controller for both
stages. Stage-specific bounded caches include languages, profile and the accepted basic pair.
Each `LearningExplanationSession` owns its pending work, frozen target and independently available
basic/details records. `LearningDictionarySession` feeds this flow from both writing and reading;
its derived vocabulary capture keeps the displayed pair and opts out of legacy explanation cache
enrichment. Saving is unavailable during the first in-flight request, before a pair exists.

`LearningReadingLookupPolicy` separates complete sentence captures from smaller targets before
any generation. `LearningReadingCoordinator` supplies receipt validation to `LearningLookupPresenting`;
`LearningSentencePanel` reuses its `LearningDetailPanel`/`LearningDictionaryCard` as a standalone
surface with the same nonactivating window, popup ownership and dismissal boundary. Complete
sentence and whole screen-region translation retain the existing translator. Pointer OCR uses
a bounded block of adjacent aligned lines, retaining uncertain outer boundaries. The shared explanation view requests details only on
expansion; the dictionary tab remains lazy when AI is configured and does not restart a stopped model task.

## Reading Context Acquisition

`Support/Accessibility/AXReadingContext.swift` owns bounded, read-only Text Marker queries for
explicit selections. It accepts sentence/paragraph ranges only after proving their lengths and
exact before/selected/after concatenation. Chromium's inline-node range quirks fall back to
paragraph-boundary marker pairs, queried just inside the selected edges to avoid neighbouring
paragraphs. Larger or unavailable structural ranges use a deadline- and step-limited marker window;
no path reads from document start to end. Opaque marker endpoints remain in the selection reader's
memory-only evidence so a different occurrence of the same spelling invalidates an older request.

`Support/LanguageLearning/LearningReadingContextPolicy.swift` validates UTF-16 code units, composed
character boundaries, exact selection location and crop budgets before making a vocabulary example.
It trims selected edge whitespace only for highlighting, preserves the original receipt for
staleness, and treats an isolated bare word as lacking surrounding context. The existing
`LearningVocabularyContextReader` tries ordinary AX ranges first and Text Markers second, logging
only acquisition method, completeness and length. Reader completion rechecks both selection range
and marker identity after these cross-process context calls.

Lookup keeps the original two-stage contract. Basic prompts omit empty detail-stage fields;
standalone dictionary queries omit context-only fields and request a positive general definition.
Known empty-answer placeholders fail validation and use the existing retry UI instead of becoming
cached meanings. Reading routing retains exact captured sentence coverage, recognizes multiword
colon-ending statements as a fallback, and keeps bare word targets trimmed independently of AX
receipt text.

`LearningReadingLanguageResolver` resolves a receipt before either reading route starts. Shared
short words borrow the captured sentence's language before the acquisition hint or isolated-word
result; a sufficiently complete selection keeps priority in mixed-language documents. Script
compatibility prevents a surrounding Chinese sentence from relabelling a selected Latin word.
Recognition remains bounded and unconstrained by the supported palette, so unknown or unsupported
languages are never silently replaced with English or the reading target language. The coordinator
logs only the chosen language, evidence source and input lengths.

Source recognition is advisory for explicit reading. `LearningExplanationInput.language`, reading
presentations and vocabulary captures carry an optional source; response and translation languages
remain concrete. Unknown sources reach the existing model with the selected text, verified context
and target language, omitting the source-language field. Generic and TranslateGemma adapters use
target-only instructions; the known-source templates remain unchanged. Automatic writing eligibility
still requires a configured source language, so this does not broaden background generation.

`LearningDictionarySession` opens the dictionary directly when no AI is configured and keeps it
available during or after failed AI work. Unknown-source lookup searches enabled local dictionaries
without an entry-language filter. Online sources remain explicitly selectable, but are not added to
automatic lookup for an unknown source; only the query reaches an explicitly selected online source.
Cache keys distinguish unknown source (`und`) from every concrete language. Speech resolves its own
optional hint; a voice-resolution failure does not block the dictionary or model result.

Saving an unknown-source capture keeps its language absent in JSON and uses `und` only in SQL
identity/index columns and CSV/TXT interchange. Known-only notebook snapshots remain version 3;
snapshots containing unknown-source entries use version 4. The SQLite table schema is unchanged.
Portable learning exports similarly retain version 1 for known-only data and use version 2 when
source language is absent. CSV import recognizes explicit `und` without applying the default language.
The existing archive remains the sole persistence boundary, and removing the last unknown entry
restores the known-only snapshot version.

## Reading Evidence And Block Reconstruction

`Models/LanguageLearning/LearningReadingContext.swift` separates the ephemeral acquisition window
from the sentence(s) used by the model/card. It records an exact target, independent left/right
boundary evidence, source method and optional OCR confidence. Complete multi-sentence selections
retain their sentence count instead of being confused with cropped sentences. Only the consumer
converts this value into a `VocabularyExample`; the receipt ID keeps that example stable during
rendering. Writing preview/notebook archive formats remain independent of acquisition internals.

`LearningReadingContextPolicy` validates UTF-16 identity, trims artificial AX crop-edge graphemes,
segments with the captured language (without an English fallback), and ranks candidate coverage.
It preserves a total 1,024-unit surrounding budget, reallocating unused capacity near field edges.
Internal sentence punctuation can establish a boundary; leading whitespace or a trailing period
at an artificial crop edge cannot establish completeness on their own.

`LearningReadingBlockPolicy` distinguishes vertically separate block frames from inline overlap.
`AXReadingContext` combines that evidence with semantic AX roles and bounded ancestor ranges.
Chromium can expose both p and span as AXGroup; layout is recorded only as an expansion hint, never as proof of sentence completeness.
The adapter continues through parent groups, so a soft-wrapped inline span cannot stop expansion. Clipped/offscreen frames retain unknown boundaries. Large containers use a
marker walk confined to the ancestor range, never a flattened web-area string. This avoids
concatenating headings/paragraphs without separators. The 180 ms context deadline is checked
between calls, not a preemptive cancellation guarantee for a synchronous AX IPC.

`LearningReadingOCRLayout` first joins nearby same-baseline fragments while retaining their original
UTF-16 source offsets. `LearningReadingOCRPolicy` then joins adjacent aligned rows around an exact hit, with
alternating expansion and the same total text budget. Worker word records carry their emitted
line index, UTF-16 range and confidence; repeated spellings never use first-match text search.
The helper/extractor retain this provenance locally; images and geometry do not enter prompts.
Screen-region capture continues to translate the explicit region and preserves low-confidence
recognized text. OCR edge evidence remains cropped unless interior sentence boundaries prove more.

Every capture, including the passive selection icon, gets a trace before acquisition. The first
lookup uses that trace; later details/refresh logs link their new request IDs through
`context_request_id`. Context diagnostics include method, both boundaries, target offset, length,
confidence and deadline status, without logging the captured text.

`LingroveTests/Fixtures/Reading/context.html` provides repeatable Chrome cases for linked history,
inline styles, repeated words, combining characters, full selections and large paragraphs. Serve
this directory on loopback, use its selection controls (or double-click a word), and inspect the
reading-context diagnostics. Pure evidence tests and the real Vision integration suite verify
routing, provenance and fragment handling independently of a model.

## OCR Primary Pointer Reading

`LearningReadingVisualReader` owns one explicit visual acquisition operation, borrowing the app's
existing `OCRRuntime`. It freezes one image, recognizes a 720×240-point local crop, and may expand
once within that same image when target/context touches a crop edge or the first crop has no hit.
It never combines text from separate recognition passes. Exact target spelling and overlapping
word geometry must agree before replacement; complete context wins over a longer fragment.
The same 12-second deadline reaches capture callbacks, OCR queueing and both native passes.
An unsuccessful expansion can retain the first verified fragment; cancellation always retires it.

`WindowScreenshotService.pointerCaptureRegion` matches Window Server front-to-back ordering to
ScreenCaptureKit window IDs, independently of AX availability. Cursor surfaces and Dock animation
shields are excluded from window hit testing; ordinary application panels still count as occluders.
Only the pointed window's visible
intersection with its display may supply the bounded frame (up to 1600×1200 points and 16M pixels).
Its memory-only window ID/frame receipt is rechecked around OCR and before model result delivery;
Lingrove's own cards are excluded. There is no screen-wide expansion when window identity is absent.
`ScreenCaptureReply` arbitrates SDK callback, timeout and cancellation once, discarding late replies.
It releases the caller without claiming to cancel ScreenCaptureKit's underlying native operation.

`LearningReadingVisualPolicy` owns pixel/point conversion, small pointer tolerance and hit ambiguity.
When Vision returns one identical box for the subtokens of a hyphenated unit, it returns that whole
printed unit rather than guessing a subword; whitespace-separated overlaps remain ambiguous.
`LearningReadingOCRLayout` retains source maps, preserves visible hyphens and CJK spacing, and
separates distant cells/columns. Row walking rejects heading-sized gaps and distinguishes hanging
list continuations from new unindented blocks. Complex tightly spaced table cells still need more
layout evidence; geometry alone cannot always distinguish them from inline text fragments.

`LearningReadingSourceReader.capturePointer` owns OCR-first/AX-fallback ordering. Known sensitive
AX fields remain blocked before capture. Missing AX metadata is not a safety proof; as with existing
explicit region reading, it does not disable user-triggered pixel capture. Missing Screen Recording
permission still allows available AX lookup. Host scroll/typing/app-switch cancellation and reader
revisions prevent a retired OCR request from launching an AX fallback. The pointer is frozen at
trigger time; moving it towards the card does not cancel the request. Dynamic content is interpreted
as the captured frame, not a continuously tracked video/text session. Selection remains AX-first.

`LingroveTests/Fixtures/Reading/ocr.html?case=history` is the browser pixel-replay fixture, with
supported/table/columns/repeated/small/mixed/cropped cases. Save viewport PNGs and a `manifest.json`
array containing `name,width,height,x,y,target` (CSS viewport size and target centre), then set
`LINGROVE_OCR_SCREENSHOTS` and `TEST_RUNNER_LINGROVE_OCR_SCREENSHOTS` to that directory to run
`ReadingOCRScreenshotTests`. Controlled native-rendering fixtures and callback/queue/lifecycle
tests run normally. Pixel replay covers OCR/layout, not ScreenCaptureKit window selection; inspect
the `reading_route`, `ocr_passes` and context trace in a live Dev acceptance as well.
