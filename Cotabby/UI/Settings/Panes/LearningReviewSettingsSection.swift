import SwiftUI

/// A presentation-only grouped form borrows the shared controller/settings. Opening this tab
/// reads the optional Keychain value; only Test Connection or a model selection performs HTTP.
struct LearningReviewSettingsSection: View {
    @ObservedObject var controller: AnkiReviewController
    @ObservedObject private var settings: AnkiReviewSettings
    @State private var key = ""
    @State private var savedKey = ""
    @State private var keyError: String?
    @FocusState private var keyFocused: Bool
    @State private var advanced = false
    @Environment(\.settingsHighlightedItem) private var highlightedItem

    init(controller: AnkiReviewController) {
        self.controller = controller; settings = controller.settings
    }

    var body: some View {
        Section(String(localized: "Anki connection", table: "Vocabulary")) {
            TextField(String(localized: "AnkiConnect address", table: "Vocabulary"), text: $settings.address)
                .settingsItem(.ankiReview)
            SecureField(String(localized: "API key (optional)", table: "Vocabulary"), text: $key)
                .focused($keyFocused).onSubmit(saveKey)
            HStack {
                Button(String(localized: "Test connection", table: "Vocabulary")) {
                    saveKey()
                    if keyError == nil { Task { await controller.testConnection() } }
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
            LabeledContent(String(localized: "Note type", table: "Vocabulary"), value: settings.model)
            if settings.model == AnkiReviewPolicy.presetName {
                Toggle(String(localized: "Recognition card", table: "Vocabulary"), isOn: $settings.defaultRecognition)
                Toggle(String(localized: "Gap card", table: "Vocabulary"), isOn: $settings.defaultGap)
            }
        }
        Section {
            DisclosureGroup(String(localized: "Advanced settings", table: "Learning"), isExpanded: $advanced) {
                Picker(String(localized: "Note type", table: "Vocabulary"), selection: $settings.model) {
                    ForEach(Array(Set((controller.catalog?.models ?? [])
                        + [settings.model, AnkiReviewPolicy.presetName])).sorted(),
                            id: \.self) { Text($0).tag($0) }
                }
                if settings.model != AnkiReviewPolicy.presetName {
                    ForEach(ReviewField.allCases) { field in
                        Picker(field.label, selection: Binding(
                            get: { settings.mapping[field] ?? "" }, set: { settings.mapping[field] = $0 })) {
                            Text(String(localized: "Not mapped", table: "Vocabulary")).tag("")
                            ForEach(Array(Set(controller.modelFields + [settings.mapping[field] ?? ""])).filter { !$0.isEmpty }.sorted(),
                                    id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
            }.settingsItem(.ankiReviewFields)
        }
        .onAppear {
            do { key = try settings.readKey(); savedKey = key } catch { keyError = error.localizedDescription }
        }
        .onDisappear(perform: saveKey)
        .onChange(of: keyFocused) { _, focused in if !focused { saveKey() } }
        .onChange(of: settings.model) { _, _ in Task { await controller.refreshFields() } }
        .onChange(of: settings.address) { _, _ in controller.invalidateConnection() }
        .onChange(of: highlightedItem, initial: true) { _, item in if item == .ankiReviewFields { advanced = true } }
    }

    private func saveKey() {
        guard key != savedKey else { return }
        do {
            try settings.saveKey(key); savedKey = key; keyError = nil
            controller.invalidateConnection()
        } catch { keyError = error.localizedDescription }
    }
}
