import LingroveNotebook
import SwiftUI

/// A presentation-only grouped form borrows the shared controller/settings. Opening this tab
/// reads the optional Keychain value; only Test Connection or a model selection performs HTTP.
struct LearningReviewSettingsSection: View {
    @ObservedObject var controller: AnkiReviewController
    @ObservedObject private var store: VocabularyStore
    @ObservedObject private var settings: AnkiReviewSettings
    @State private var showsAnki = false
    @State private var key = ""
    @State private var savedKey = ""
    @State private var keyError: String?
    @FocusState private var keyFocused: Bool
    @Environment(\.settingsHighlightedItem) private var highlightedItem

    init(controller: AnkiReviewController) {
        self.controller = controller; settings = controller.settings; store = controller.store
    }

    var body: some View {
        Group {
            Section {
                Picker(String(localized: "Review", table: "Vocabulary"), selection: $showsAnki) {
                    Text("Lingrove").tag(false)
                    Text("Anki").tag(true)
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("settings.review.destination")
            }
            if showsAnki { ankiSettings } else {
                Section("Lingrove") {
                    Button(BuiltInReviewCopy.text("action.openReview")) { store.onRequestBuiltInReview?(nil) }
                        .accessibilityIdentifier("settings.review.lingrove.open")
                }
                Section(String(localized: "Card templates", table: "Vocabulary")) {
                    Button(String(localized: "Card templates", table: "Vocabulary")) { store.onRequestReviewTemplates?() }
                }
            }
        }
        .onAppear { store.loadIfNeeded(); revealAnki(highlightedItem) }
        .onChange(of: highlightedItem) { _, value in revealAnki(value) }
    }

    @ViewBuilder private var ankiSettings: some View {
        Group {
            Section(String(localized: "Anki connection", table: "Vocabulary")) {
                TextField(String(localized: "AnkiConnect address", table: "Vocabulary"), text: $settings.address)
                    .settingsItem(.ankiReview)
                SecureField(String(localized: "API key (optional)", table: "Vocabulary"), text: $key)
                    .focused($keyFocused).onSubmit(saveKey)
                HStack {
                    Button(String(localized: "Test connection", table: "Vocabulary")) {
                        saveKey()
                        if keyError == nil { Task { await controller.testConnection(model: ReviewLayoutPolicy.model) } }
                    }.disabled(controller.testing || controller.sendingSenseID != nil)
                    if controller.testing { ProgressView().controlSize(.small) }
                    if let message = keyError ?? controller.connectionMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if let catalog = controller.catalog {
                    LabeledContent(String(localized: "Anki profile", table: "Vocabulary"), value: catalog.profile)
                }
            }
            Section(String(localized: "Default cards", table: "Vocabulary")) {
                if let catalog = controller.catalog {
                    Picker(String(localized: "Deck", table: "Vocabulary"), selection: $settings.deck) {
                        ForEach(Array(Set(catalog.decks + [settings.deck])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField(String(localized: "Deck", table: "Vocabulary"), text: $settings.deck)
                }
                LabeledContent(String(localized: "Note type", table: "Vocabulary"), value: ReviewLayoutPolicy.model)
            }
            templates
        }
        .onAppear {
            do { key = try settings.readKey(); savedKey = key } catch { keyError = error.localizedDescription }
        }
        .onDisappear(perform: saveKey)
        .onChange(of: keyFocused) { _, focused in if !focused { saveKey() } }
        .onChange(of: settings.address) { _, _ in controller.invalidateConnection() }
    }

    private var templates: some View {
        Section(String(localized: "Card templates", table: "Vocabulary")) {
            ForEach(store.reviewTemplates) { template in
                HStack {
                    Text(template.name)
                    Spacer()
                    Button(role: .destructive) { Task { [scope = store.operationScope] in
                        try? await store.removeTemplate(template.id, scope: scope) } } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.borderless).help(String(localized: "Delete", table: "Vocabulary"))
                }
            }
        }.settingsItem(.ankiReviewFields)
    }

    private func revealAnki(_ item: SettingsItem?) {
        if item == .ankiReview || item == .ankiReviewFields { showsAnki = true }
    }

    private func saveKey() {
        guard key != savedKey else { return }
        do {
            try settings.saveKey(key); savedKey = key; keyError = nil
            controller.invalidateConnection()
        } catch { keyError = error.localizedDescription }
    }
}
