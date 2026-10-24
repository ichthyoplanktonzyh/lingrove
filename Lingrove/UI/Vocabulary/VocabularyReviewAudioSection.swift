import SwiftUI

/// This section edits only opt-in audio choices. Generation and audition are explicit actions;
/// it observes the session's shared speech preparation rather than creating another provider.
struct VocabularyReviewAudioSection: View {
    @ObservedObject var session: AnkiReviewSession
    @Binding var operation: Task<Void, Never>?
    var body: some View {
        Section(String(localized: "Audio", table: "Vocabulary")) {
            ForEach(ReviewAudioKind.allCases) { kind in
                HStack {
                    Toggle(kind.label, isOn: Binding(get: { session.plan.audioKinds?.contains(kind) == true }, set: { enabled in
                        var kinds = session.plan.audioKinds ?? []
                        if enabled { kinds.insert(kind) } else { kinds.remove(kind) }
                        session.plan.audioKinds = kinds
                        if let field = session.mapping[kind.field] { session.plan.fieldOverrides[field] = nil }
                    })).disabled(kind == .sentence && session.content?.sentence.isEmpty != false &&
                        session.plan.audioKinds?.contains(kind) != true)
                    if session.audio.generating == kind { ProgressView().controlSize(.small) }
                    if session.plan.audioKinds?.contains(kind) == true {
                        Button(String(localized: "Preview audio", table: "Vocabulary")) {
                            perform { await session.prepareAudio(kind, audition: true) }
                        }
                        Button(String(localized: "Regenerate audio", table: "Vocabulary")) {
                            perform { await session.prepareAudio(kind, audition: false, force: true) }
                        }
                    }
                }
            }
        }
    }
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard operation == nil else { return }
        operation = Task { defer { operation = nil }; await action() }
    }
}
