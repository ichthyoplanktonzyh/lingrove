import SwiftUI

/// One saved occurrence supplies its own meaning and explanation. The window-owned notebook
/// session lends this row a stable explanation session, so examples never display each other's
/// results and closing the window can cancel every outstanding operation explicitly.
struct VocabularyExplanationSection: View {
    let entry: VocabularyEntry
    let sense: VocabularySense
    var example: VocabularyExample?
    @ObservedObject var store: VocabularyStore
    @ObservedObject var learning: VocabularyNotebookSession

    var body: some View {
        if let session = learning.explanations[VocabularyNotebookSession.key(example)] {
            let meaning = example?.meaning ?? sense.meaning
            let origin = example?.meaningOrigin ?? sense.meaningOrigin
            let hasContent = !meaning.isEmpty || session.record != nil || session.isGenerating || session.error != nil
            VStack(alignment: .leading, spacing: hasContent ? 8 : 0) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(session.record != nil || session.isGenerating ? CotabbyBrand.accent : .secondary)
                        .accessibilityHidden(true)
                    Text(example == nil ? String(localized: "General meaning", table: "Vocabulary")
                        : String(localized: "Meaning in this context", table: "Vocabulary"))
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    LearningExplanationButton(session: session,
                        prepare: { learning.activateExplanation(VocabularyNotebookSession.key(example)) },
                        configure: { (session.service as? LearningExplanationService)?.configure?() })
                }
                LearningExplanationView(session: session,
                    configure: { (session.service as? LearningExplanationService)?.configure?() },
                    adopt: { record in
                        Task { _ = await store.adoptExplanation(record,
                            at: .init(entryID: entry.id, senseID: sense.id, exampleID: example?.id)) }
                    }, presentation: .contextual,
                    meaning: example == nil || origin == .user || session.record == nil ? meaning : nil)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
    }
}
