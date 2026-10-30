import SwiftUI

/// The window borrows the app's existing learning settings. Observing them here updates only
/// the display context; the nested notebook keeps its selection, filters and graph camera.
/// No view creates a settings store or changes the languages attached to saved expressions.
struct VocabularyNotebookRoot: View {
    @ObservedObject var settings: LanguageLearningSettings
    let store: VocabularyStore
    let speech: LearningSpeechController
    var selectedID: UUID?
    var selectedSenseID: UUID?
    let learning: VocabularyNotebookSession
    var review: AnkiReviewController?
    var search: VocabularySearchController?
    var preferences: UserDefaults = .standard

    var body: some View {
        VocabularyNotebookView(store: store, speech: speech, selectedID: selectedID, selectedSenseID: selectedSenseID,
            learning: learning, review: review, search: search, preferences: preferences)
            .environment(\.vocabularyMeaningLanguages,
                VocabularyMeaningLabelPolicy.preferredLanguages(explanation: settings.explanationLanguage))
    }
}
