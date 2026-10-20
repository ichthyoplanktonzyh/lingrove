import SwiftUI

/// A notebook window lends this section its one explanation session. Selection is local UI
/// state; immutable entry/example captures go to the same service used by floating cards.
/// Loading a saved annotation never triggers a model request or changes a user's meaning.
struct VocabularyExplanationSection: View {
    let entry: VocabularyEntry
    @ObservedObject var store: VocabularyStore
    @ObservedObject var session: LearningExplanationSession
    @State private var selectedExampleID: UUID?
    @State private var standalone = false

    private var example: VocabularyExample? {
        if standalone { return nil }
        if let selectedExampleID, let example = entry.examples.first(where: { $0.id == selectedExampleID }) { return example }
        return entry.examples.first
    }
    private var input: LearningExplanationInput {
        LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, example: example))
    }
    private var saved: LearningExplanationRecord? {
        entry.explanations?.last { $0.input == input && $0.language == session.service?.language }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: "AI explanation", table: "Learning")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                LearningExplanationButton(session: session,
                    configure: { (session.service as? LearningExplanationService)?.configure?() })
            }
            if entry.examples.count + (entry.isSavedWithoutContext ? 1 : 0) > 1 {
                Picker(String(localized: "Example sentence", table: "Vocabulary"), selection: Binding(
                    get: { example?.id.uuidString ?? "standalone" }, set: {
                        standalone = $0 == "standalone"; selectedExampleID = UUID(uuidString: $0)
                    })) {
                    if entry.isSavedWithoutContext { Text(entry.expression).tag("standalone") }
                    ForEach(entry.examples) { Text($0.text).lineLimit(2).tag($0.id.uuidString) }
                }
            }
            LearningExplanationView(session: session,
                configure: { (session.service as? LearningExplanationService)?.configure?() },
                adopt: { record in
                    let destination = VocabularyExplanationDestination(entryID: entry.id, exampleID: example?.id)
                    Task { _ = await store.adoptExplanation(record, at: destination) }
                })
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: input, initial: true) { _, input in session.setTarget(input, saved: saved) }
        .onChange(of: saved) { _, saved in session.setTarget(input, saved: saved) }
        .onDisappear { if session.input == input { session.cancel() } }
    }
}
