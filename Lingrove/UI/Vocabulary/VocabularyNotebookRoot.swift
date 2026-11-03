import SwiftUI

/// The window borrows the app's existing learning settings. Observing them here updates only
/// the display context; the nested notebook keeps its selection, filters and graph camera.
/// No view creates a settings store or changes the languages attached to saved expressions.
struct VocabularyNotebookRoot: View {
    @ObservedObject var settings: LanguageLearningSettings
    @ObservedObject var store: VocabularyStore
    let speech: LearningSpeechController
    var selectedID: UUID?
    var selectedSenseID: UUID?
    let learning: VocabularyNotebookSession
    var review: AnkiReviewController?
    var builtInReview: BuiltInReviewSession?
    var search: VocabularySearchController?
    var preferences: UserDefaults = .standard

    var body: some View {
        VocabularyNotebookView(store: store, speech: speech, selectedID: selectedID, selectedSenseID: selectedSenseID,
            learning: learning, review: review, builtInReview: builtInReview, search: search, preferences: preferences)
            .id(store.scopeIdentity)
            .onChange(of: store.scopeIdentity) { _, _ in learning.reset() }
            .environment(\.vocabularyMeaningLanguages,
                VocabularyMeaningLabelPolicy.preferredLanguages(explanation: settings.explanationLanguage))
    }
}
