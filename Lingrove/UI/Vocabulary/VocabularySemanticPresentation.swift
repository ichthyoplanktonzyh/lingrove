import SwiftUI

/// One inherited display context reaches lists, graph projections, details and sheets. It is
/// a presentation value, not another persisted language setting or a label translation service.
private nonisolated struct VocabularyMeaningLanguagesKey: EnvironmentKey {
    static var defaultValue: [LearningLanguage] { VocabularyMeaningLabelPolicy.preferredLanguages() }
}

extension EnvironmentValues {
    var vocabularyMeaningLanguages: [LearningLanguage] {
        get { self[VocabularyMeaningLanguagesKey.self] }
        set { self[VocabularyMeaningLanguagesKey.self] = newValue }
    }
}

/// The source language belongs to the saved expression. Unknown metadata remains explicit;
/// a badge never borrows the interface language or the language currently used for explanation.
struct VocabularyExpressionLanguageBadge: View {
    let language: LearningLanguage?
    var body: some View {
        Text(language?.compactLabel ?? String(localized: "Unspecified", table: "Learning"))
            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
    }
}

/// Visual badge distinguishing content concepts ("what is meant") from communicative functions
/// ("what the speaker is doing") across meaning headers and sidebars.
struct VocabularyMeaningKindBadge: View {
    let kind: VocabularyMeaningNode.Kind
    private var tint: Color {
        kind == .concept ? LingroveBrand.accent : .teal
    }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 9, weight: .semibold))
            Text(kind.label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.11), in: Capsule(style: .continuous))
    }
}

/// Highlights `[slot]` placeholders inside a usage pattern template so learners can immediately
/// distinguish fixed wording from variable grammatical slots.
struct VocabularyPatternTemplateText: View {
    let template: String
    var font: Font = .callout.weight(.semibold)

    var body: some View {
        Text(highlightedTemplate)
            .font(font)
            .textSelection(.enabled)
    }

    private var highlightedTemplate: AttributedString {
        var result = AttributedString(template)
        guard let regex = try? NSRegularExpression(pattern: "\\[[^\\[\\]]+\\]") else { return result }
        let nsRange = NSRange(template.startIndex..<template.endIndex, in: template)
        for match in regex.matches(in: template, range: nsRange) {
            guard let range = Range(match.range, in: template),
                  let attrRange = Range(range, in: result) else { continue }
            result[attrRange].foregroundColor = LingroveBrand.accent
            result[attrRange].backgroundColor = LingroveBrand.accent.opacity(0.11)
        }
        return result
    }
}

extension VocabularyGraphEdge.Kind {
    var label: String {
        switch self {
        case .ownership: String(localized: "Sense", table: "Vocabulary")
        case .expressesContent: String(localized: "Expressed by", table: "Vocabulary")
        case .realizesFunction: String(localized: "Expressed by", table: "Vocabulary")
        case .narrower: String(localized: "More specific than", table: "Vocabulary")
        case .opposite: String(localized: "Opposite", table: "Vocabulary")
        case .related: String(localized: "Related", table: "Vocabulary")
        }
    }
}

/// UI wording is kept out of graph identity and storage. All semantic screens share these
/// labels, so the list, graph legend and editors describe the same relation in the same way.
extension VocabularyMeaningNode.Kind {
    var label: String {
        switch self {
        case .concept: String(localized: "Content concept", table: "Vocabulary")
        case .function: String(localized: "Communicative function", table: "Vocabulary")
        }
    }
    var symbolName: String {
        switch self {
        case .concept: "circle.hexagongrid"
        case .function: "bubble.left.and.bubble.right"
        }
    }
}
extension VocabularyMeaningRelation.Kind {
    var label: String {
        switch self {
        case .narrower: String(localized: "More specific than", table: "Vocabulary")
        case .opposite: String(localized: "Opposite", table: "Vocabulary")
        case .related: String(localized: "Related", table: "Vocabulary")
        }
    }
}
extension VocabularyUsagePattern.Formality {
    var label: String {
        switch self {
        case .unspecified: String(localized: "Unspecified", table: "Learning")
        case .informal: String(localized: "Informal", table: "Vocabulary")
        case .neutral: String(localized: "Neutral", table: "Vocabulary")
        case .formal: String(localized: "Formal", table: "Vocabulary")
        }
    }
}
extension VocabularyUsagePattern.Medium {
    var label: String {
        switch self {
        case .unspecified: String(localized: "Unspecified", table: "Learning")
        case .spoken: String(localized: "Spoken", table: "Vocabulary")
        case .written: String(localized: "Written", table: "Vocabulary")
        case .both: String(localized: "Spoken and written", table: "Vocabulary")
        }
    }
}

/// Semantic sheets follow the existing notebook's grouped-form and value-draft convention.
/// This shared shell only presents controls; its caller owns the draft and archive transaction.
struct VocabularySemanticEditorFrame<Content: View>: View {
    let title: String
    let saving: Bool
    let canSave: Bool
    let failure: String?
    let save: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(18)
            Divider()
            Form(content: content).formStyle(.grouped).disabled(saving)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).padding(12) }
            Divider()
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(saving)
                Button(String(localized: "Save", table: "Vocabulary"), action: save)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(saving || !canSave)
            }.padding(16)
        }
        .frame(width: 560, height: 420)
        .interactiveDismissDisabled(saving)
    }
}

/// Readable usage information is shared by comparison cards and expression details. Technical
/// slot identities stay in storage; learners see wording, register and practical restrictions.
struct VocabularyUsagePatternSummary: View {
    let pattern: VocabularyUsagePattern

    private var registerBadges: [String] {
        [
            pattern.formality == .unspecified ? "" : pattern.formality.label,
            pattern.medium == .unspecified ? "" : pattern.medium.label,
            pattern.region.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VocabularyPatternTemplateText(template: pattern.template)
                ForEach(registerBadges, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule(style: .continuous))
                }
                if pattern.provenance.status == .proposed {
                    Text(String(localized: "Suggested wording", table: "Vocabulary"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: Capsule(style: .continuous))
                }
            }
            if !pattern.note.isEmpty {
                Text(pattern.note)
                    .font(.callout)
                    .foregroundStyle(.primary.opacity(0.88))
                    .textSelection(.enabled)
            }
            if !pattern.collocations.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "link")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(pattern.collocations.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// A candidate classification is a concrete decision, never a mutable status field. The
/// component borrows the app store and submits a conflict-checked edit of the exact mapping.
/// Both browsing modes use this presentation, including the original example when available.
struct VocabularyMeaningMappingSummary: View {
    @ObservedObject var store: VocabularyStore
    let mapping: VocabularyMeaningMapping
    let sense: VocabularySense?
    var showsExample = true
    var showsActionsMenu = true
    let edit: () -> Void
    @State private var saving = false

    private var pattern: VocabularyUsagePattern? {
        store.semantics.patterns.first { $0.id == mapping.patternID }
    }

    private var resolvedExample: VocabularyExample? {
        guard showsExample, let sense else { return nil }
        return VocabularySemanticEditingPolicy.example(for: mapping, sense: sense)
    }

    private var hasBodyContent: Bool {
        pattern != nil || !mapping.nuance.isEmpty || !mapping.conditions.isEmpty ||
            resolvedExample != nil || !mapping.provenance.source.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasBodyContent {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 7) {
                        if let pattern {
                            VocabularyUsagePatternSummary(pattern: pattern)
                        }
                        if !mapping.nuance.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(LingroveBrand.accent)
                                Text(mapping.nuance)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                        if !mapping.conditions.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "scope")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(mapping.conditions)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        if let example = resolvedExample {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(highlighted(example))
                                    .font(.callout)
                                    .textSelection(.enabled)
                                if !example.translation.isEmpty {
                                    Text(example.translation)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.leading, 10)
                            .padding(.vertical, 2)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(LingroveBrand.accent.opacity(0.35))
                                    .frame(width: 2.5)
                            }
                        }
                        if !mapping.provenance.source.isEmpty {
                            DisclosureGroup(String(localized: "Source note", table: "Vocabulary")) {
                                Text(mapping.provenance.source)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if showsActionsMenu && mapping.provenance.status != .proposed {
                        actionsMenu
                    }
                }
            } else if showsActionsMenu && mapping.provenance.status != .proposed {
                HStack {
                    Spacer()
                    actionsMenu
                }
            }

            if mapping.provenance.status == .proposed {
                HStack(spacing: 8) {
                    Label(String(localized: "Suggested grouping", table: "Vocabulary"), systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    Button(String(localized: "Use this grouping", table: "Vocabulary")) { confirm() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .disabled(saving)
                        .accessibilityIdentifier("vocabularyConfirmGrouping")
                    Button(String(localized: "Change", table: "Learning"), action: edit)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    if showsActionsMenu {
                        actionsMenu
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button(String(localized: "Change", table: "Learning"), action: edit)
            Divider()
            Button(String(localized: "Remove from this group", table: "Vocabulary"), role: .destructive) { remove() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(saving)
    }

    private func highlighted(_ example: VocabularyExample) -> AttributedString {
        var result = AttributedString(example.text)
        for value in example.ranges {
            guard VocabularyPolicy.valid(value.nsRange, in: example.text),
                  let range = Range(value.nsRange, in: example.text),
                  let converted = Range(range, in: result) else { continue }
            result[converted].font = .callout.weight(.semibold)
            result[converted].foregroundColor = LingroveBrand.accent
            result[converted].backgroundColor = LingroveBrand.accent.opacity(0.11)
        }
        return result
    }

    private func confirm() {
        let baseline = store.semantics; var edited = baseline
        guard let index = edited.mappings.firstIndex(where: { $0.id == mapping.id }), edited.mappings[index] == mapping else { return }
        edited.mappings[index].provenance.status = .confirmed
        submit(edited, baseline: baseline)
    }
    private func remove() {
        let baseline = store.semantics; var edited = baseline
        edited.mappings.removeAll { $0.id == mapping.id }
        submit(edited, baseline: baseline)
    }
    private func submit(_ edited: VocabularySemanticIndex, baseline: VocabularySemanticIndex) {
        saving = true
        Task { _ = await store.updateSemantics(edited, basedOn: baseline); saving = false }
    }
}

/// Meaning navigation retains the originating concept when drilling into a sense. The same
/// sense detail can therefore be reused without adding a permanent third window column.
enum VocabularyMeaningDestination: Hashable {
    case node(UUID)
    case sense(nodeID: UUID?, senseID: UUID)
    case unclassified

    var nodeID: UUID? {
        switch self {
        case .node(let id): id
        case .sense(let id, _): id
        case .unclassified: nil
        }
    }
    var senseID: UUID? {
        if case .sense(_, let id) = self { id } else { nil }
    }
}
