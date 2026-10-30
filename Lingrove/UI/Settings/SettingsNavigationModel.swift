import Combine
import SwiftUI

/// The fixed Engine & Model tabs select which task's settings are visible. This is window
/// navigation state, independent of the engine/model values that control actual generation.
enum SettingsEngineTask: String, CaseIterable, Identifiable, Hashable {
    case completion, translation, explanation, speech, vocabularySearch
    var id: String { rawValue }
    var label: String {
        switch self {
        case .completion: String(localized: "Autocomplete")
        case .translation: String(localized: "Translation", table: "Learning")
        case .explanation: String(localized: "Explanation & expression", table: "Learning")
        case .speech: String(localized: "TTS", table: "Learning")
        case .vocabularySearch: String(localized: "Expression search", table: "Vocabulary")
        }
    }
    init(role: LearningModelRole) {
        switch role {
        case .translation: self = .translation
        case .explanation: self = .explanation
        }
    }
}

/// The behavior areas in Language Learning are window navigation, not feature toggles.
/// The settings window retains the selected area while model links visit Engine & Model;
/// search selects the area before mounting its Form so row reveal always has a visible target.
enum SettingsLearningTask: String, CaseIterable, Identifiable, Hashable {
    case translation, explanation, readAloud, dictionary, review
    var id: String { rawValue }
    var label: String {
        switch self {
        case .translation: String(localized: "Translation", table: "Learning")
        case .explanation: String(localized: "Explanation & expression", table: "Learning")
        case .readAloud: String(localized: "Read Aloud", table: "Learning")
        case .dictionary: String(localized: "Dictionary", table: "Learning")
        case .review: String(localized: "Review", table: "Vocabulary")
        }
    }
}

/// File overview:
/// Navigation state for the Settings window: which pane is selected, which individual setting
/// (if any) search wants revealed, and a pending request to focus the Home search field. Owned by
/// `SettingsContainerView` and shared with the sidebar and Home so a search hit anywhere can land
/// on the exact row: select the pane, scroll to the row, and pulse it briefly.
///
/// The highlight is deliberately transient. It exists to answer "where did search drop me?",
/// not to become persistent selection state, so `reveal` schedules its own clear and any manual
/// pane switch cancels it immediately.
@MainActor
final class SettingsNavigationModel: ObservableObject {
    /// The settings window owns one read-only guide sheet. Closing it never changes a feature.
    @Published var showsUsageGuide = false

    /// Guide links dismiss the sheet and reuse search's precise routing in the same UI update.
    /// Keeping this transition here prevents a help link from losing the selected learning tab.
    func openUsageGuideDestination(_ item: SettingsItem) {
        showsUsageGuide = false
        reveal(item)
    }

    @Published var shortcutAppBundleIdentifier: String?

    /// Menu shortcuts name a precise destination instead of reopening whichever tab happened
    /// to be selected last. The same routing methods also clear stale search highlights.
    func openMenuDestination(_ destination: MenuBarSettingsDestination) {
        switch destination {
        case .category(let category): open(category)
        case .learning(let task): openLearningTask(task)
        case .model(let task): openEngineTask(task)
        }
    }

    func openShortcuts(for bundleIdentifier: String? = nil) {
        shortcutAppBundleIdentifier = bundleIdentifier
        open(.shortcuts)
    }
    /// Plain reference, assigned by the window, so tracing cannot invalidate SwiftUI itself.
    var renderDiagnostics: SettingsRenderDiagnostics?
    @Published var selection: SettingsCategory = .home {
        didSet {
            if selection != oldValue { renderDiagnostics?.begin(selection) }
        }
    }
    @Published var engineTask: SettingsEngineTask = .completion
    @Published var learningTask: SettingsLearningTask = .translation
    @Published var modelManagerTask: SettingsEngineTask?
    @Published private(set) var expandedEngineTasks: Set<SettingsEngineTask> = []
    /// Browsing a dormant completion backend is UI navigation, so users can configure endpoint
    /// credentials before adding a power profile without changing the engine currently running.
    @Published var inspectedCompletionEngine: SuggestionEngineKind?

    /// Window-only routes keep management, advanced controls and search in one state machine.
    /// Selecting a file remains the task controller's job, never a side effect of opening a sheet.
    func openModelManager(_ task: SettingsEngineTask) {
        openEngineTask(task)
        modelManagerTask = task
    }

    func modelManagerBinding(for task: SettingsEngineTask) -> Binding<Bool> {
        Binding(get: { self.modelManagerTask == task }, set: { presented in
            if presented { self.modelManagerTask = task } else if self.modelManagerTask == task { self.modelManagerTask = nil }
        })
    }

    func advancedBinding(for task: SettingsEngineTask) -> Binding<Bool> {
        Binding(get: { self.expandedEngineTasks.contains(task) }, set: { expanded in
            if expanded { self.expandedEngineTasks.insert(task) } else { self.expandedEngineTasks.remove(task) }
        })
    }
    /// The setting search navigated to, while its arrival pulse is active. Distributed to rows
    /// through the `settingsHighlightedItem` environment value.
    @Published private(set) var highlightedItem: SettingsItem?
    /// The search destination survives its short arrival pulse, so an explicit backend action
    /// remains available until the user navigates away. Search itself never changes a backend.
    @Published private(set) var revealedItem: SettingsItem?
    @Published private(set) var revealSequence = 0
    /// True while Home owes the hero search field focus (set by the window-level Cmd-F shortcut).
    /// Home consumes and clears it, so a later visit to Home does not steal focus again.
    @Published private(set) var pendingSearchFocus = false

    private var highlightClearTask: Task<Void, Never>?

    /// How long the arrival pulse stays before fading. Long enough to catch the eye after the
    /// pane switch and scroll settle, short enough to never read as a stuck selection.
    private static let highlightDuration: Duration = .seconds(2.4)

    /// Plain pane navigation (sidebar click, Home quick link). Cancels any in-flight highlight so
    /// a stale pulse cannot replay when the user later returns to that pane.
    func open(_ category: SettingsCategory) {
        inspectedCompletionEngine = nil
        modelManagerTask = nil
        cancelHighlight()
        selectCategory(category)
    }

    /// Writing's model links choose both the category and the task before SwiftUI renders the
    /// destination. Keeping this here lets sidebar/search and cross-pane links share one owner.
    func openLearningModel(_ role: LearningModelRole) {
        openEngineTask(SettingsEngineTask(role: role))
    }

    /// Task-specific links (including Home's completion engine card) land on the matching page
    /// even if the user last inspected a different task. Plain sidebar navigation keeps the tab.
    func openEngineTask(_ task: SettingsEngineTask) {
        engineTask = task
        open(.engineAndModel)
    }

    /// A manual tab change clears an old search pulse, while ordinary sidebar navigation keeps
    /// this window's last selected learning area. No model or generation setting is written.
    func openLearningTask(_ task: SettingsLearningTask) {
        learningTask = task
        open(.languageLearning)
    }

    // swiftlint:disable cyclomatic_complexity
    /// Search navigation: selects the item's pane and pulses the row. The pane's scaffold watches
    /// `highlightedItem` to perform the scroll.
    /// One exhaustive navigation map keeps every searchable destination in the same transaction.
    func reveal(_ item: SettingsItem) {
        inspectedCompletionEngine = nil
        modelManagerTask = nil
        // Existing engine search anchors belong to the original completion page. A prior visit
        // to translation must not leave those search hits scrolling an unrelated learning form.
        if item.category == .engineAndModel {
            switch item {
            case .vocabularySearch: engineTask = .vocabularySearch
            case .translationModel, .translationSampling: engineTask = .translation
            case .explanationModel, .explanationParameters: engineTask = .explanation
            case .speechSampling, .speechProvider, .speechLanguage, .speechVoice, .speechModel, .speechDecoder, .speechEndpoint,
                .speechEndpointModel, .speechEndpointVoice:
                engineTask = .speech
            default:
                engineTask = .completion
            }
        }
        if item.category == .languageLearning {
            switch item {
            case .readAloudSpeed: learningTask = .readAloud
            case .dictionarySources: learningTask = .dictionary
            case .ankiReview, .ankiReviewFields: learningTask = .review
            case .explanationLanguage, .expressionAssist: learningTask = .explanation
            default: learningTask = .translation
            }
        }
        if item.opensModelManager { modelManagerTask = engineTask }
        if item.opensEngineAdvanced { expandedEngineTasks.insert(engineTask) }
        selectCategory(item.category)
        revealedItem = item
        showArrival(for: item)
    }
    // swiftlint:enable cyclomatic_complexity

    /// An explicit configure action has mounted the previously hidden row. Re-run its one-shot
    /// arrival after layout, even if the same search target's decorative pulse is still active.
    func refreshReveal() {
        guard let item = revealedItem else { return }
        showArrival(for: item)
    }

    private func showArrival(for item: SettingsItem) {
        highlightedItem = item
        revealSequence &+= 1

        highlightClearTask?.cancel()
        highlightClearTask = Task { [weak self] in
            try? await Task.sleep(for: Self.highlightDuration)
            guard !Task.isCancelled else { return }
            self?.highlightedItem = nil
        }
    }

    /// Cmd-F: focus the active search field in place. On Home this focuses the hero search bar;
    /// on any detail pane the sidebar search field takes focus without losing the current pane.
    func requestSearchFocus() {
        cancelHighlight()
        pendingSearchFocus = true
    }

    func consumeSearchFocusRequest() {
        pendingSearchFocus = false
    }

    private func cancelHighlight() {
        highlightClearTask?.cancel()
        highlightClearTask = nil
        highlightedItem = nil
        revealedItem = nil
    }

    /// Re-selecting a category can still clear a search pulse or retarget its app/task, but it
    /// should not publish a second, identical category mutation and rebuild the detail needlessly.
    private func selectCategory(_ category: SettingsCategory) {
        guard selection != category else { return }
        selection = category
    }
}

// MARK: - Highlight environment

/// The item whose arrival pulse is active, distributed as a plain environment value (rather than
/// the model object) so rows re-render only when the value actually changes.
private struct SettingsHighlightedItemKey: EnvironmentKey {
    static let defaultValue: SettingsItem? = nil
}

private struct SettingsRevealSequenceKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var settingsRevealSequence: Int {
        get { self[SettingsRevealSequenceKey.self] }
        set { self[SettingsRevealSequenceKey.self] = newValue }
    }
    var settingsHighlightedItem: SettingsItem? {
        get { self[SettingsHighlightedItemKey.self] }
        set { self[SettingsHighlightedItemKey.self] = newValue }
    }
}

// MARK: - Row anchor

extension View {
    /// Marks a settings row as the home of `item` so search can scroll to it (`.id`) and pulse it
    /// on arrival. Apply to the outermost row view inside a Form section (the `Toggle`, `Picker`,
    /// or `LabeledContent` itself).
    func settingsItem(_ item: SettingsItem) -> some View {
        modifier(SettingsItemAnchorModifier(item: item))
    }
}

private struct SettingsItemAnchorModifier: ViewModifier {
    let item: SettingsItem
    @Environment(\.settingsHighlightedItem) private var highlightedItem
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let isHighlighted = highlightedItem == item
        content
            .id(item)
            // The wash draws behind the row content rather than via `listRowBackground`, which
            // macOS grouped forms ignore. An always-present background whose opacity animates to
            // zero keeps the idle row untouched (opacity 0 renders nothing) while letting the
            // pulse fade smoothly instead of vanishing when the highlight clears. Pairing the
            // fill wash with a subtle accent border ring makes the target row unmistakable on
            // arrival without affecting layout geometry.
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(isHighlighted ? 0.14 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(isHighlighted ? 0.42 : 0), lineWidth: 1.5)
                    )
                    .padding(.horizontal, -8)
                    .padding(.vertical, -5)
                    .animation(
                        SettingsMotion.resolved(.easeInOut(duration: 0.45), reduceMotion: reduceMotion),
                        value: isHighlighted
                    )
            )
    }
}
