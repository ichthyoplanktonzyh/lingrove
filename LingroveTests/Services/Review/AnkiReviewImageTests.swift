import Foundation
import LingroveNotebook
import Testing
@testable import Lingrove

/// Note media uses the real source owner and sender with a synthetic Anki transport. These
/// checks protect upload/retry identity and profile fences without retaining a recipe editor.
@Suite(.serialized) @MainActor
struct NoteAnkiMediaTests {
    @Test func imageUploadAndLostReplyReuseTheSameNote() async throws {
        try await withImage { fixture, fake, controller, selection, filename in
            let session = NoteAnkiSession(controller: controller, selection: selection)
            await session.load()
            fake.lose("addNote")
            #expect(!(await session.send()))
            #expect(fake.mediaNames().contains(filename))
            #expect(await session.send())
            #expect(fake.count() == 1)
            #expect(fake.fields()["RichContent"]?.contains(filename) == true)
            let review = try fixture.repository.engine.loadLingroveNotebookReviewSnapshot(scope: fixture.repository.snapshot())
            #expect(review.groups.isEmpty)
        }
    }

    @Test func profileChangeDuringImageUploadRejectsNoteCreation() async throws {
        try await withImage { _, fake, controller, selection, _ in
            let session = NoteAnkiSession(controller: controller, selection: selection)
            await session.load()
            fake.switchProfileDuringNextMediaUpload()
            #expect(!(await session.send()))
            #expect(fake.count() == 0)
        }
    }

    private func withImage(_ body: (NotebookWorkspaceFixture, NoteAnkiFake, AnkiReviewController,
                                    VocabularySelection, String) async throws -> Void) async throws {
        let fixture = try NotebookWorkspaceFixture()
        do {
            let selection = try await fixture.seed()
            let original = try #require(fixture.store.entries.first { $0.id == selection.entryID })
            let image = try await fixture.store.prepareImage(VocabularyImageTestFixture.png())
            var edited = original
            edited.senses[0].content = [.init(content: .image(image.reference, caption: "Synthetic harbor"))]
            #expect(await fixture.store.update(edited, basedOn: original, importedImages: [image.reference.filename: image.data]))
            let fake = NoteAnkiFake()
            let controller = AnkiReviewController(settings: fixture.anki.settings, store: fixture.store,
                repository: fixture.repository, client: fake, activateAnki: {})
            try await body(fixture, fake, controller, selection, image.reference.filename)
            await fixture.cleanUp()
        } catch { await fixture.cleanUp(); throw error }
    }
}
