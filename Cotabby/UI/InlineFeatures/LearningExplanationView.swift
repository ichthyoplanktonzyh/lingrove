import SwiftUI

/// The same presentation appears inside dictionary, sentence and notebook cards. Its owner
/// supplies a session and optional adoption action; this view neither constructs a runtime nor
/// writes an editor. Long explanations remain in the surrounding card's bounded scroll viewport.
struct LearningExplanationView: View {
    /// A surrounding card may already own the target and generation button. Embedded results
    /// observe the same session while omitting those duplicate controls and adding separation.
    enum Presentation { case complete, embedded, contextual }
    @ObservedObject var session: LearningExplanationSession
    var configure: () -> Void = {}
    var adopt: ((LearningExplanationRecord) -> Void)?
    var presentation: Presentation = .complete
    var meaning: String?
    var context: VocabularyExample?
    var detailsChanged: (Bool) -> Void = { _ in }
    @State private var showsDetails = false

    var body: some View {
        if presentation == .contextual {
            contextualContent
        } else if presentation == .complete || session.record != nil || session.isGenerating || session.error != nil {
            content
        }
    }

    /// Contextual lookup leads with the sense of this occurrence. The same result can be used
    /// in the notebook with a user-owned meaning; a new model result then remains a proposal
    /// inside Details until explicitly adopted, rather than silently replacing the user's text.
    private var contextualContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let text = meaning ?? session.record?.result.meaning, !text.isEmpty {
                Text(text).font(.callout.weight(.semibold)).textSelection(.enabled)
            }
            if let context {
                VStack(alignment: .leading, spacing: 6) {
                    if context.completeness == .fragment {
                        Text(String(localized: "Context fragment", table: "Vocabulary")).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(contextualExample(context)).font(.callout).textSelection(.enabled)
                    if !context.translation.isEmpty {
                        Text(context.translation).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            if let record = session.record {
                DisclosureGroup(String(localized: "Details", table: "Learning"), isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let meaning, meaning != record.result.meaning {
                            Text(record.result.meaning).font(.callout.weight(.semibold)).textSelection(.enabled)
                            if let adopt {
                                Button(String(localized: "Replace contextual meaning", table: "Learning")) { adopt(record) }
                                    .buttonStyle(.link).font(.caption)
                            }
                        }
                        Text(record.result.explanation).font(.callout).textSelection(.enabled)
                    }.padding(.top, 6)
                }.font(.caption)
            }
            if session.isGenerating {
                Text(String(localized: "Explaining…", table: "Learning")).font(.caption).foregroundStyle(.secondary)
            } else if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: session.input) { _, _ in showsDetails = false }
        .onChange(of: showsDetails) { _, expanded in detailsChanged(expanded) }
    }

    private func contextualExample(_ example: VocabularyExample) -> AttributedString {
        var result = AttributedString(example.text)
        for value in example.ranges {
            guard let range = Range(value.nsRange, in: example.text), let converted = Range(range, in: result) else { continue }
            result[converted].foregroundColor = .blue
            result[converted].font = .body.bold()
        }
        return result
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if presentation == .embedded { Divider() }
            if presentation == .complete, let input = session.input {
                Text(input.target).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if let record = session.record {
                Text(record.result.meaning).font(.callout.weight(.semibold)).textSelection(.enabled)
                Text(record.result.explanation).font(.callout).textSelection(.enabled)
                if presentation == .complete || adopt != nil {
                    HStack {
                        if presentation == .complete {
                            Button(String(localized: "Regenerate", table: "Learning")) { session.explain(refresh: true) }
                                .disabled(session.isGenerating || !session.isConfigured)
                        }
                        if let adopt {
                            Button(String(localized: "Use as contextual meaning", table: "Learning")) { adopt(record) }
                        }
                    }.buttonStyle(.link).font(.caption)
                }
            }
            if session.isGenerating {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "Explaining…", table: "Learning")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Stop", table: "Learning"), action: session.cancel).buttonStyle(.link)
                }
            } else if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                if presentation == .complete {
                    Button(String(localized: "Try again", table: "Learning")) { session.explain(refresh: true) }.buttonStyle(.link)
                }
            } else if session.record == nil, presentation == .complete {
                if session.isConfigured {
                    Button(String(localized: "AI explanation", table: "Learning")) { session.explain() }.buttonStyle(.link)
                        .disabled(session.input == nil)
                } else {
                    Button(String(localized: "Configure AI explanation model", table: "Learning"), action: configure).buttonStyle(.link)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A card lends this control its existing session. Deriving feedback from that session keeps
/// restored results, cancellation and target changes in sync without another UI state machine.
/// Every phase uses the same hit area; the progress ring remains a button that can stop work.
struct LearningExplanationButton: View {
    @ObservedObject var session: LearningExplanationSession
    var prepare: () -> Void = {}
    var configure: () -> Void = {}
    var body: some View {
        Button {
            // Stopping must not invoke `prepare`: in a compact card it would expand the details
            // even though the user only asked to cancel the request at its original location.
            if session.isGenerating { session.cancel(); return }
            prepare()
            if session.isConfigured {
                session.explain(refresh: session.record != nil || session.error != nil)
            } else { configure() }
        } label: {
            Group {
                if session.isGenerating {
                    ProgressView().controlSize(.mini).tint(.blue)
                        .allowsHitTesting(false).accessibilityHidden(true)
                } else {
                    Image(systemName: "sparkles").font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(tint)
            .frame(width: 22, height: 22).contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .disabled(session.input == nil)
            .help(tooltip)
            .accessibilityLabel(actionLabel)
            .accessibilityHint(session.error ?? "")
    }

    private var tint: Color {
        if session.isGenerating { return .blue }
        if !session.isConfigured { return .secondary }
        if session.error != nil { return .orange }
        return session.record == nil ? .secondary : .blue
    }

    private var actionLabel: String {
        if session.isGenerating { return String(localized: "Stop generating explanation", table: "Learning") }
        if !session.isConfigured { return String(localized: "Configure AI explanation model", table: "Learning") }
        if session.error != nil { return String(localized: "Try again", table: "Learning") }
        return session.record == nil ? String(localized: "AI explanation", table: "Learning")
            : String(localized: "Regenerate explanation", table: "Learning")
    }

    private var tooltip: String {
        if let error = session.error, session.isConfigured, !session.isGenerating {
            return actionLabel + "\n" + error
        }
        return actionLabel
    }
}

/// A saved card supplies a captured occurrence; the store resolves its durable destination.
/// Observing the store makes adoption appear immediately after favoriting, without model work.
struct LearningCapturedExplanationView: View {
    @ObservedObject var session: LearningExplanationSession
    @ObservedObject var store: VocabularyStore
    let capture: VocabularyCapture
    var configure: () -> Void = {}
    var presentation: LearningExplanationView.Presentation = .complete
    var context: VocabularyExample?
    var detailsChanged: (Bool) -> Void = { _ in }
    var body: some View {
        let destination = store.explanationDestination(capture)
        LearningExplanationView(session: session, configure: configure, adopt: destination.map { destination in
            { record in Task { _ = await store.adoptExplanation(record, at: destination) } }
        }, presentation: presentation, meaning: presentation == .contextual ? destination.flatMap(store.userMeaning) : nil,
            context: context, detailsChanged: detailsChanged)
    }
}
