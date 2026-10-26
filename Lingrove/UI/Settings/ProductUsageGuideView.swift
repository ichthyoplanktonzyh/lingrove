import SwiftUI

/// The Settings window owns this guide and its selected topic. Reading help only observes the
/// existing settings; an explicit example opens the same local player used by Home. Settings
/// links return to the window owner's exact-row navigation instead of constructing services.
struct ProductUsageGuideView: View {
    @ObservedObject var settings: SuggestionSettingsModel
    let open: (SettingsItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var topic = UsageGuideTopic.completion
    @State private var example: UsageGuideTopic?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(String(localized: "Usage Guide", table: "Learning")).font(.title2.weight(.semibold))
                Spacer()
                Button(String(localized: "Close", table: "Learning")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 0) {
                List(selection: $topic) {
                    topicRow(.completion)
                    Section(String(localized: "Language Learning", table: "Learning")) {
                        ForEach(UsageGuideTopic.allCases.filter { $0 != .completion }, content: topicRow)
                    }
                }.listStyle(.sidebar).frame(width: 180).accessibilityIdentifier("usageGuideTopics")
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Label(topic.title, systemImage: topic.symbol).font(.title3.weight(.semibold))
                            Spacer()
                            Button(String(localized: "View example", table: "Learning")) { example = topic }
                                .accessibilityIdentifier("usageGuideExample")
                        }
                        ForEach(Array(topic.steps.enumerated()), id: \.offset) { index, instruction in
                            HStack(alignment: .top, spacing: 10) {
                                Text(verbatim: "\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20).background(.quaternary, in: Circle())
                                Text(instruction).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                        if topic == .expression {
                            ExpressionAssistIntroduction(settings: settings.languageLearning.expressionAssist, open: open)
                        }
                        UsageGuideShortcuts(topic: topic, settings: settings, learning: settings.languageLearning,
                            vocabulary: settings.vocabularyShortcuts, open: open)
                        Divider()
                        Text(String(localized: "Related settings", table: "Learning")).font(.headline)
                        ForEach(topic.destinations) { item in
                            Button { open(item) } label: { Label(item.title, systemImage: item.systemImage) }
                                .buttonStyle(.borderless).accessibilityIdentifier("usageGuide.settings." + item.rawValue)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.id(topic).accessibilityIdentifier("usageGuideContent")
            }
        }
        .padding(20).frame(width: 780, height: 580)
        .sheet(item: $example) { topic in
            ProductFeatureExample(title: topic.title, scene: topic.scene, settings: settings.languageLearning)
        }
        .accessibilityIdentifier("productUsageGuide")
    }

    private func topicRow(_ topic: UsageGuideTopic) -> some View {
        Label { Text(topic.title).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: topic.symbol)
        }.tag(topic).padding(.vertical, 4)
            .accessibilityIdentifier("usageGuide.topic." + topic.rawValue)
    }
}

/// A small navigation value keeps each topic's instructions, settings destinations and existing
/// example together. It lives with the guide, owns no session, and never changes a feature.
private enum UsageGuideTopic: String, CaseIterable, Identifiable {
    case completion, writing, expression, reading, lookup, speech, vocabulary, review
    var id: String { rawValue }
    var scene: HomeLearningScene? {
        switch self {
        case .completion: nil
        case .expression: .expression
        case .writing: .writing
        case .reading: .reading
        case .lookup: .lookup
        case .speech: .speech
        case .vocabulary: .vocabulary
        case .review: .anki
        }
    }
    var title: String {
        switch self {
        case .completion: String(localized: "Autocomplete")
        case .expression: String(localized: "Expression assistance", table: "Learning")
        case .writing: String(localized: "Writing translation", table: "Learning")
        case .reading: String(localized: "Reading translation", table: "Learning")
        case .lookup: String(localized: "Dictionary", table: "Learning") + " · " + String(localized: "AI explanation", table: "Learning")
        case .speech: String(localized: "Read Aloud", table: "Learning")
        case .vocabulary: String(localized: "Vocabulary", table: "Vocabulary")
        case .review: String(localized: "Anki review", table: "Vocabulary")
        }
    }
    var symbol: String {
        switch self {
        case .completion: "text.cursor"
        case .expression: "text.magnifyingglass"
        case .writing: "character.bubble"
        case .reading: "text.viewfinder"
        case .lookup: "book.closed"
        case .speech: "speaker.wave.2"
        case .vocabulary: "books.vertical"
        case .review: "rectangle.stack"
        }
    }
    var destinations: [SettingsItem] {
        switch self {
        case .completion: [.completionEnabled, .engine, .disabledApps, .emojiPicker, .inlineMacros, .accessibility, .inputMonitoring]
        case .expression: [.expressionAssist, .explanationModel, .expressionAssistShortcut]
        case .writing: [.translationEnabled, .translationModel, .sentencePreview, .translationTargetLanguage, .translationReferenceMode]
        case .reading: [.selectionTranslation, .pointerTranslation, .screenshotTranslation, .selectionTranslationApps, .screenRecording]
        case .lookup: [.explanationModel, .explanationLanguage, .dictionarySources]
        case .speech: [.speechProvider, .readAloudSpeed]
        case .vocabulary: [.commandLineTools]
        case .review: [.ankiReview, .ankiReviewFields]
        }
    }
    var steps: [String] {
        switch self {
        case .completion:
            [String(localized: "Start typing in an editable field, then pause to see a suggestion.", table: "Learning"),
             String(localized: "Insert the next word or the entire suggestion with your configured shortcuts.", table: "Learning"),
             String(localized: "Choose which apps use autocomplete in App settings.", table: "Learning")]
        case .expression:
            instructions([.expressionTrigger, .expressionDescribe, .expressionInsert])
        case .writing:
            instructions([.preview, .expand, .replace]) + [String(localized:
                "Selections take priority. Reference context never expands the replacement range.", table: "Learning")]
        case .reading:
            instructions([.select, .pointer, .capture]) + [String(localized:
                "Reading translation leaves the original text unchanged. Screen OCR requires Screen Recording permission.",
                table: "Learning")]
        case .lookup:
            instructions([.lookup, .explain, .dictionary, .sources]) + [String(localized:
                "With context, AI explains this usage; without context, it gives common meanings.", table: "Learning")]
        case .speech:
            [String(localized:
                "Click the speaker beside a word, expression, or sentence. The language follows the text.", table: "Learning"),
             HomeLearningDemoAction.speak.explanation]
        case .vocabulary:
            instructions([.favorite, .favoriteMenu, .list, .graph, .headword, .sense]) + [String(localized:
                "Open Vocabulary from the menu bar to search, edit, or add text and images to a sense.",
                table: "Learning"),
                String(localized:
                    "Use Export in Vocabulary to save TXT, CSV, or JSON. Include images to export a ZIP package.", table: "Learning")]
        case .review:
            [String(localized: "Open Anki with AnkiConnect, then test the connection in Review settings.", table: "Learning"),
             String(localized: "Select a saved sense and add a card. You can also update an existing card.", table: "Learning")]
                + instructions([.layout, .addAnki, .reviewAnki])
        }
    }
    private func instructions(_ actions: [HomeLearningDemoAction]) -> [String] { actions.map(\.explanation) }
}

/// Only the shortcut section observes the nested stores. Rebinding a key updates its label
/// immediately, including disabled keys and double-tap acceptance; help never installs bindings.
private struct UsageGuideShortcuts: View {
    let topic: UsageGuideTopic
    @ObservedObject var settings: SuggestionSettingsModel
    @ObservedObject var learning: LanguageLearningSettings
    @ObservedObject var vocabulary: VocabularyShortcutSettings
    let open: (SettingsItem) -> Void
    var body: some View {
        if [.completion, .writing, .reading, .vocabulary].contains(topic) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(localized: "Global shortcuts", table: "Learning")).font(.headline)
                    rows
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    @ViewBuilder private var rows: some View {
        switch topic {
        case .completion:
            row(.acceptWord, key: settings.acceptanceKeyCode, label: settings.acceptanceKeyLabel)
            CurrentShortcutRow(title: SettingsItem.acceptEntireSuggestion.title,
                isBound: settings.hasFullAcceptanceShortcut, label: settings.fullAcceptanceDisplayLabel) {
                    open(.acceptEntireSuggestion)
                }
        case .writing:
            row(.replacementTranslationShortcut, key: learning.replacementKeyCode, label: learning.replacementKeyLabel)
            row(.translationDetailsShortcut, key: learning.keyCode, label: learning.keyLabel)
        case .reading:
            ForEach(LearningReadingSource.allCases, id: \.rawValue) { source in
                let binding = learning.readingBinding(source)
                row(source == .selection ? .selectionTranslationShortcut
                    : source == .pointer ? .pointerTranslationShortcut : .screenshotTranslationShortcut,
                    key: binding.key, label: binding.label)
            }
        case .vocabulary:
            ForEach(VocabularyShortcutSettings.Command.allCases, id: \.rawValue) { command in
                let binding = vocabulary.binding(command)
                row(command == .save ? .saveVocabularyShortcut : .openVocabularyShortcut, key: binding.key, label: binding.label)
            }
        default: EmptyView()
        }
    }
    private func row(_ item: SettingsItem, key: UInt16, label: String) -> some View {
        CurrentShortcutRow(title: item.title, isBound: key != .max, label: label) { open(item) }
    }
}
