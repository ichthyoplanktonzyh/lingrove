import Foundation
import Testing
@testable import Cotabby

extension AnkiReviewTests {
    @Test func imageAnswerUploadsBeforeNoteAndUpdatesKeepStableIdentity() async throws {
        let (controller, fake, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let baseline = controller.store.entries[0]
        let image = try await controller.store.prepareImage(VocabularyImageTestFixture.png())
        var edited = baseline
        edited.senses[0].content = [.init(content: .image(image.reference, caption: "A river bank"))]
        #expect(await controller.store.update(edited, basedOn: baseline, importedImages: [image.reference.filename: image.data]))
        let first = try session(controller)
        first.plan.answer = ""; first.plan.gap = false
        await fake.loseNextAddReply()
        #expect(await first.send() == false)
        #expect(await fake.mediaCount() == 1)
        let retry = try session(controller)
        #expect(await retry.send())
        let noteID = try #require(controller.store.entries[0].senses[0].review?.activeBinding?.noteID)
        #expect(await fake.values(noteID)?["Meaning"]?.contains(image.reference.filename) == true)
        #expect(await fake.counts().add == 1)
        let update = try session(controller)
        update.plan.answer = "River bank"
        #expect(await update.send())
        #expect(controller.store.entries[0].senses[0].review?.activeBinding?.noteID == noteID)
        #expect(await fake.counts().add == 1)
    }

    @Test func legacyGapTemplateMustUpgradeBeforeSendingSenseContent() async throws {
        let (controller, fake, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let baseline = controller.store.entries[0]
        var edited = baseline
        edited.senses[0].content = [.init(content: .text(.init(text: "secret explanation")))]
        #expect(await controller.store.update(edited, basedOn: baseline))
        await fake.setLegacyTemplate()
        let draft = try session(controller)
        draft.plan.gap = true
        #expect(await draft.send() == false)
        #expect(await fake.counts().add == 0)
        await draft.updateTemplate()
        #expect(await draft.send())
        #expect(await fake.counts().add == 1)
    }

    @Test func profileChangingDuringImageUploadCannotCreateNote() async throws {
        let (controller, fake, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let baseline = controller.store.entries[0]
        let image = try await controller.store.prepareImage(VocabularyImageTestFixture.png())
        var edited = baseline
        edited.senses[0].content = [.init(content: .image(image.reference, caption: ""))]
        #expect(await controller.store.update(edited, basedOn: baseline, importedImages: [image.reference.filename: image.data]))
        await fake.switchProfileAfterNextMedia("Other profile")
        #expect(try await session(controller).send() == false)
        #expect(await fake.counts().add == 0)
    }

    @Test(arguments: [false, true]) func finalTemplateReadCannotRedirectWritesToAnotherProfile(updating: Bool) async throws {
        let (controller, fake, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        if updating { #expect(try await session(controller).send()) }
        let baseline = controller.store.entries[0]
        var edited = baseline
        edited.senses[0].content = [.init(content: .text(.init(text: "A financial institution")))]
        #expect(await controller.store.update(edited, basedOn: baseline))
        let draft = try session(controller)
        draft.plan.includeSenseContent = true; draft.plan.gap = true
        await fake.switchProfileOnSecondTemplateRead()
        #expect(await draft.send() == false)
        #expect(await fake.counts().add == (updating ? 1 : 0))
        #expect(await fake.counts().update == 0)
    }
}
