import SwiftUI

/// The same presentation appears inside dictionary, sentence and notebook cards. Its owner
/// supplies a session and optional adoption action; this view neither constructs a runtime nor
/// writes an editor. Long explanations remain in the surrounding card's bounded scroll viewport.
struct LearningExplanationView: View {
    /// A surrounding card may already own the target and generation button. Embedded results
    /// observe the same session while omitting those duplicate controls and adding separation.
    enum Presentation { case complete, embedded }
    @ObservedObject var session: LearningExplanationSession
    var configure: () -> Void = {}
    var adopt: ((LearningExplanationRecord) -> Void)?
    var presentation: Presentation = .complete

    var body: some View {
        if presentation == .complete || session.record != nil || session.isGenerating || session.error != nil {
            content
        }
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

/// A compact trigger observes only explanation state, so streamed generation status cannot
/// invalidate the sentence's TextKit layout or its caret geometry.
struct LearningExplanationButton: View {
    @ObservedObject var session: LearningExplanationSession
    var prepare: () -> Void = {}
    var configure: () -> Void = {}
    var body: some View {
        Button {
            prepare()
            if session.isConfigured {
                session.explain(refresh: session.record != nil || session.error != nil)
            } else { configure() }
        } label: {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .disabled(session.input == nil || session.isGenerating)
            .help(String(localized: "AI explanation", table: "Learning"))
            .accessibilityLabel(String(localized: "AI explanation", table: "Learning"))
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
    var body: some View {
        let destination = store.explanationDestination(capture)
        LearningExplanationView(session: session, configure: configure, adopt: destination.map { destination in
            { record in Task { _ = await store.adoptExplanation(record, at: destination) } }
        }, presentation: presentation)
    }
}
