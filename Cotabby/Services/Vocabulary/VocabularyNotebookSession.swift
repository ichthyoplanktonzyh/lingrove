import Combine
import Foundation

/// The notebook window owns this presentation lifetime. Each visible saved usage borrows its
/// own lightweight explanation session from the app's one explainer; all are cancelled when
/// selection changes or the window closes. One independent dictionary session serves the live
/// reference section, using the same provider/settings as floating cards and no AI auto-query.
@MainActor
final class VocabularyNotebookSession: ObservableObject {
    @Published private(set) var explanations: [String: LearningExplanationSession] = [:]
    let dictionary: LearningDictionarySession
    private let service: (any LearningExplanationGenerating)?
    private(set) var entryID: UUID?
    private var dictionaryEntry: VocabularyEntry?

    init(service: (any LearningExplanationGenerating)? = nil, provider: any LearningDictionaryProviding,
         settings: LearningDictionarySettings? = nil) {
        self.service = service
        dictionary = LearningDictionarySession(provider: provider, settings: settings)
    }

    static func key(_ example: VocabularyExample?) -> String { example?.id.uuidString ?? "standalone" }

    func select(_ entry: VocabularyEntry?) {
        if entryID != entry?.id {
            cancel()
            explanations = [:]
            dictionaryEntry = nil
        }
        entryID = entry?.id
        guard let entry else { return }
        var next: [String: LearningExplanationSession] = [:]
        let examples: [VocabularyExample?] = (entry.isSavedWithoutContext ? [nil] : []) + entry.examples.map(Optional.some)
        for example in examples {
            let key = Self.key(example)
            let session = explanations[key] ?? LearningExplanationSession(service: service)
            let input = LearningExplanationPolicy.input(LearningExplanationPolicy.capture(entry, example: example))
            let saved = entry.explanations?.last { $0.input == input && $0.language == service?.language }
            session.setTarget(input, saved: saved)
            next[key] = session
        }
        for (key, session) in explanations where next[key] == nil { session.cancel() }
        explanations = next
        if let previous = dictionaryEntry,
           previous.dictionaryForm != entry.dictionaryForm || previous.language != entry.language {
            dictionary.close()
            dictionaryEntry = nil
        }
    }

    func activateExplanation(_ key: String) {
        for (other, session) in explanations where other != key { session.cancel() }
    }

    func showDictionary(_ entry: VocabularyEntry) {
        let text = entry.dictionaryForm.isEmpty ? entry.expression : entry.dictionaryForm
        guard dictionary.documentID != entry.id || dictionary.query != text else { return }
        dictionaryEntry = entry
        let unit = LearningUnit(id: 0, surface: text, query: text,
            kind: entry.kind == .word ? .word : .expression,
            ranges: [NSRange(location: 0, length: text.utf16.count)],
            words: LearningUnitPolicy.words(in: text, language: entry.language))
        dictionary.open(unit, documentID: entry.id, language: entry.language)
    }

    func hideDictionary() { dictionary.close(); dictionaryEntry = nil }
    func resume() { if let entry = dictionaryEntry { showDictionary(entry) } }
    func cancel() {
        for session in explanations.values { session.cancel() }
        dictionary.close()
    }
}
