import SwiftUI

/// A draft sheet shares the notebook's native grouped form conventions. Preview uses plain
/// SwiftUI text, never executes Anki templates/remote HTML. The preset has predictable front/back
/// previews; custom note types show the exact mapped fields and keep rendering under Anki's control.
struct VocabularyReviewSheet: View {
    @StateObject private var session: AnkiReviewSession
    @Environment(\.dismiss) private var dismiss
    @State private var back = false
    @State private var gapPreview = false

    init(controller: AnkiReviewController, entry: VocabularyEntry, sense: VocabularySense) {
        _session = StateObject(wrappedValue: AnkiReviewSession(controller: controller, entry: entry, sense: sense))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                preparation
                if session.model == AnkiReviewPolicy.presetName { presetPreview } else { mappedPreview }
                if !session.conflicts.isEmpty { conflictSection }
                if let validation = session.validationMessage {
                    Section { Text(validation).font(.caption).foregroundStyle(.secondary) }
                }
                if let message = session.message { Section { Text(message).foregroundStyle(.red).textSelection(.enabled) } }
            }.formStyle(.grouped).disabled(session.busy)
            HStack {
                Button(String(localized: "Review settings", table: "Vocabulary")) {
                    Task {
                        if await session.save() { dismiss(); session.controller.configure?() }
                    }
                }.buttonStyle(.link)
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Save", table: "Vocabulary")) { Task { if await session.save() { dismiss() } } }
                if session.busy || session.loading { ProgressView().controlSize(.small) }
                Button(session.missingNote ? String(localized: "Re-add to Anki", table: "Vocabulary")
                    : session.binding?.noteID == nil ? String(localized: "Add to Anki", table: "Vocabulary")
                    : String(localized: "Update Anki", table: "Vocabulary")) {
                    Task { if await session.send(recreateMissing: session.missingNote) { dismiss() } }
                }.keyboardShortcut(.defaultAction)
                    .disabled(session.loading || session.validationMessage != nil ||
                        session.conflicts.contains { session.keepRemote[$0.id] == nil })
            }.padding().disabled(session.busy)
        }
        .frame(width: 680, height: 690).interactiveDismissDisabled(session.busy)
        .task(id: session.bindingID) { await session.load() }
    }

    @ViewBuilder private var preparation: some View {
        Section(String(localized: "Review", table: "Vocabulary")) {
            if let review = session.current?.sense.review, review.bindings.count > 1 {
                Picker(String(localized: "Anki association", table: "Vocabulary"), selection: Binding(
                    get: { session.bindingID }, set: { session.selectBinding($0) })) {
                    Text(String(localized: "Choose…", table: "Vocabulary")).tag(nil as UUID?)
                    ForEach(review.bindings) { binding in
                        Text(binding.profile + " · " + (binding.noteID.map(String.init)
                            ?? String(localized: "Ready to send", table: "Vocabulary"))).tag(Optional(binding.id))
                    }
                }
            }
            if let catalog = session.catalog {
                Picker(String(localized: "Deck", table: "Vocabulary"), selection: $session.deck) {
                    ForEach(Array(Set(catalog.decks + [session.deck])).sorted(), id: \.self) { Text($0).tag($0) }
                }.disabled(session.binding?.noteID != nil)
                LabeledContent(String(localized: "Anki profile", table: "Vocabulary"), value: catalog.profile)
            } else {
                TextField(String(localized: "Deck", table: "Vocabulary"), text: $session.deck)
                    .disabled(session.binding?.noteID != nil)
            }
            LabeledContent(String(localized: "Note type", table: "Vocabulary"), value: session.model)
            if let current = session.current {
                Picker(String(localized: "Review example", table: "Vocabulary"), selection: Binding(
                    get: { session.plan.exampleID }, set: { id in
                        session.plan.exampleID = id
                        if !session.canGap { session.plan.gap = false }
                        session.plan.fieldOverrides = [:]
                    })) {
                    Text(String(localized: "No context", table: "Vocabulary")).tag(nil as UUID?)
                    ForEach(current.sense.examples) { Text($0.text).lineLimit(1).tag(Optional($0.id)) }
                }
                if let preserved = current.sense.review?.preservedPlans, !preserved.isEmpty {
                    Menu(String(localized: "Preserved review plans", table: "Vocabulary")) {
                        ForEach(preserved) { plan in
                            Button(plan.answer ?? current.sense.displayTitle) { session.restorePlan(plan) }
                        }
                    }
                }
            }
            TextField(String(localized: "Review answer", table: "Vocabulary"), text: Binding(
                get: { session.answer }, set: { session.plan.answer = $0 }), axis: .vertical).lineLimit(2...5)
            if session.model == AnkiReviewPolicy.presetName {
                HStack {
                    Toggle(String(localized: "Recognition card", table: "Vocabulary"), isOn: $session.plan.recognition)
                        .disabled(session.hasExistingCard(.recognition))
                    Toggle(String(localized: "Gap card", table: "Vocabulary"), isOn: $session.plan.gap)
                        .disabled(!session.canGap && !session.plan.gap ||
                            session.hasExistingCard(.gapPrompt))
                }
                if session.binding?.noteID != nil {
                    Text(String(localized: "Manage existing card types in Anki.", table: "Vocabulary"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(String(localized: "Card types follow the Anki template.", table: "Vocabulary"))
                    .font(.caption).foregroundStyle(.secondary)
                if session.mapping[.gapPrompt] != nil, session.mapping[.gapAnswer] != nil {
                    Toggle(String(localized: "Gap card", table: "Vocabulary"), isOn: $session.plan.gap)
                        .disabled(!session.canGap && !session.plan.gap || session.hasExistingCard(.gapPrompt))
                    if session.hasExistingCard(.gapPrompt) {
                        Text(String(localized: "Manage existing card types in Anki.", table: "Vocabulary"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !session.canGap {
                Text(String(localized: "A gap card requires valid expression positions in an example.", table: "Vocabulary"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(String(localized: "Include notes", table: "Vocabulary"), isOn: $session.plan.includeNotes)
            Toggle(String(localized: "Include AI explanation", table: "Vocabulary"), isOn: $session.plan.includeExplanation)
            if !session.plan.fieldOverrides.isEmpty {
                Button(String(localized: "Use notebook fields again", table: "Vocabulary")) { session.plan.fieldOverrides = [:] }
            }
        }
    }

    private var presetPreview: some View {
        Section(String(localized: "Card preview", table: "Vocabulary")) {
            HStack {
                Picker(String(localized: "Card type", table: "Vocabulary"), selection: $gapPreview) {
                    Text(String(localized: "Recognition card", table: "Vocabulary")).tag(false)
                    Text(String(localized: "Gap card", table: "Vocabulary")).tag(true)
                }.labelsHidden().pickerStyle(.segmented)
                Picker(String(localized: "Card side", table: "Vocabulary"), selection: $back) {
                    Text(String(localized: "Front", table: "Vocabulary")).tag(false)
                    Text(String(localized: "Back", table: "Vocabulary")).tag(true)
                }.labelsHidden().pickerStyle(.segmented)
            }
            if let content = session.content, let fields = try? AnkiReviewPolicy.fields(content: content,
                identity: session.binding?.originSenseID ?? session.senseID, mapping: AnkiReviewPolicy.presetMapping,
                overrides: session.plan.fieldOverrides) {
                let plain: (ReviewField) -> String = {
                    DictionaryContentPolicy.plainText(fields[$0.rawValue] ?? "").replacingOccurrences(of: "&#39;", with: "'")
                }
                let enabled = gapPreview ? !(fields[ReviewField.gapPrompt.rawValue] ?? "").isEmpty
                    : !(fields[ReviewField.recognition.rawValue] ?? "").isEmpty
                VStack(alignment: .leading, spacing: 10) {
                    if !enabled { Text(String(localized: "This card is not enabled.", table: "Vocabulary")) } else {
                        Text(gapPreview ? plain(.gapPrompt) : plain(.sentence).isEmpty ? plain(.expression) : plain(.sentence))
                        if gapPreview { Text(plain(.meaning)).font(.caption).foregroundStyle(.secondary) }
                    }
                    if back && enabled {
                        Divider()
                        if gapPreview { Text(plain(.gapAnswer)); Text(plain(.sentence)) }
                        Text(plain(.meaning)).fontWeight(.semibold)
                        Text(plain(.expression))
                        Text(plain(.translation)).foregroundStyle(.secondary)
                        if !plain(.notes).isEmpty { Text(plain(.notes)).font(.callout) }
                        if !plain(.explanation).isEmpty { Text(plain(.explanation)).font(.callout) }
                    }
                }.textSelection(.enabled).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var mappedPreview: some View {
        Section(String(localized: "Mapped fields", table: "Vocabulary")) {
            if let content = session.content, let fields = try? AnkiReviewPolicy.fields(content: content,
                identity: session.binding?.originSenseID ?? session.senseID, mapping: session.mapping,
                overrides: session.plan.fieldOverrides) {
                ForEach(fields.keys.sorted(), id: \.self) { field in
                    LabeledContent(field) { Text(fields[field] ?? "").textSelection(.enabled) }
                }
            }
        }
    }

    private var conflictSection: some View {
        Section(String(localized: "Anki fields changed", table: "Vocabulary")) {
            ForEach(session.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 6) {
                    Text(conflict.id).fontWeight(.semibold)
                    Text("Lingrove: " + conflict.local).font(.callout).textSelection(.enabled)
                    Text("Anki: " + conflict.remote).font(.callout).textSelection(.enabled)
                    Picker(String(localized: "Keep version", table: "Vocabulary"), selection: Binding(
                        get: { session.keepRemote[conflict.id] }, set: { session.keepRemote[conflict.id] = $0 })) {
                        Text(String(localized: "Choose…", table: "Vocabulary")).tag(nil as Bool?)
                        Text("Anki").tag(Optional(true))
                        Text("Lingrove").tag(Optional(false))
                    }
                }
            }
        }
    }
}
