import LingroveNotebook
import SwiftUI

/// Home owns a disposable example repository only while this scene is mounted. It uses the
/// production editor/session, synthetic corpus and the demo's existing speech owner; it never
/// reads the user's corpus or treats saving a sample as enrollment.
struct HomeLearningBuiltInReviewDemo: View {
    let speech: LearningSpeechController
    @State private var example: HomeBuiltInReviewExample?
    @State private var showing = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("harbor").font(.title2.weight(.semibold))
            Text("a sheltered place for boats").foregroundStyle(.secondary)
            Button(BuiltInReviewCopy.text("home.tryReview")) { showing = true }
                .buttonStyle(.borderedProminent).disabled(example == nil)
                .accessibilityIdentifier("homeReview.lingrove.open")
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
        .task {
            var created: HomeBuiltInReviewExample?
            do {
                let value = try HomeBuiltInReviewExample(speech: speech)
                created = value
                try await value.prepare()
                try Task.checkCancellation()
                example = value
            } catch {
                await created?.shutdown()
                if !Task.isCancelled { failure = BuiltInReviewCopy.text("error.load") }
            }
        }
        .sheet(isPresented: $showing) {
            if let example {
                VStack(spacing: 0) {
                    HStack {
                        Text("Lingrove").font(.headline)
                        Spacer()
                        Button(String(localized: "Close", table: "ReviewCards")) { showing = false }
                            .keyboardShortcut(.cancelAction).disabled(example.session.isMutating)
                    }.padding()
                    BuiltInReviewWindowView(session: example.session)
                }.frame(width: 780, height: 700)
            }
        }
        .onDisappear {
            if let example { Task { await example.shutdown() } }
            example = nil
        }
    }
}

/// This example owns its repository and corpus projection together. Shutdown drains an accepted
/// writer before closing SQLite and removes only its uniquely named temporary directory.
@MainActor
private final class HomeBuiltInReviewExample {
    let directory: URL
    let repository: MacNotebookRepository
    let store: VocabularyStore
    let session: BuiltInReviewSession

    init(speech: LearningSpeechController) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-home-review-" + UUID().uuidString)
        do {
            repository = try .init(databaseURL: directory.appendingPathComponent("notebook.sqlite"),
                mediaDirectoryURL: directory.appendingPathComponent("media"))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        store = .init(repository: repository)
        session = .init(repository: repository, speech: speech)
        session.materialStore = store
        session.materialSpeech = speech
    }

    func prepare() async throws {
        await store.save(.init(expression: "harbor", dictionaryForm: "harbor", language: .english,
            kind: .word, meaning: "a sheltered place for boats", meaningLanguage: .english))
        try Task.checkCancellation()
        session.open(selection: nil)
        await session.waitForIdle()
    }

    func shutdown() async {
        await session.shutdownAfterDraining()
        await store.shutdown()
        try? repository.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}
