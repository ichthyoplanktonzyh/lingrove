import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Lingrove

/// Exercises flexible cards through the real archive/session boundaries with an isolated Anki
/// server. Distinct cards share source content but never identity, receipts or draft CAS state.
extension AnkiReviewTests {
    @Test func flexibleCardsKeepIndependentIdentityAndRecoverLostAcknowledgement() async throws {
        let (controller, fake, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let first = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        let second = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        #expect(await first.save())
        #expect(await second.save())
        await first.load(); await fake.loseNextAddReply()
        #expect(await first.send() == false)
        #expect(await first.send(), Comment(rawValue: first.message ?? ""))
        await second.load(); #expect(await second.send(), Comment(rawValue: second.message ?? ""))
        let cards = try #require(controller.store.entries.first?.senses.first?.reviewCards)
        #expect(cards.count == 2)
        #expect(Set(cards.compactMap { $0.activeBinding?.noteID }).count == 2)
        #expect(Set(cards.compactMap { $0.activeBinding?.originSenseID }) == Set(cards.map { $0.plan.id }))
        #expect(await fake.counts().add == 2)
        let id = try #require(first.binding?.noteID)
        first.plan.layout?.back.append(.init(source: .custom, content: [.init(content: .text(.init(text: "A personal hint")))]))
        #expect(await first.send(), Comment(rawValue: first.message ?? ""))
        #expect(await fake.counts().add == 2)
        #expect(await fake.values(id)?["Back"]?.contains("A personal hint") == true)
        #expect(controller.isSynchronized(try #require(controller.store.entries.first),
            try #require(controller.store.entries.first?.senses.first), cardID: first.cardID))
    }

    @Test func flexibleCardImageQuestionHidesCaptionAndAudioStaysOnChosenSide() async throws {
        let (controller, _, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        var entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let image = try await controller.store.prepareImage(VocabularyImageTestFixture.png())
        let block = VocabularyContentBlock(content: .image(image.reference, caption: "Answer: bank"))
        entry.senses[0].content = [block]
        #expect(await controller.store.update(entry, basedOn: try #require(controller.store.entries.first),
            importedImages: [image.reference.filename: image.data]))
        sense = try #require(controller.store.entries.first?.senses.first)
        let session = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        session.plan.layout = .init(front: [.init(source: .senseImage, blockID: block.id)],
            back: [.init(source: .expression), .init(source: .expressionAudio)])
        let content = try #require(session.content)
        let values = try AnkiReviewPolicy.fields(content: content, identity: try #require(session.cardID),
            mapping: ReviewLayoutPolicy.mapping, overrides: [:], audio: [.expressionAudio: "[sound:test.wav]"])
        #expect(values["Front"]?.contains("<img") == true)
        #expect(values["Front"]?.contains("Answer: bank") == false)
        #expect(values["Front"]?.contains("[sound:") == false)
        #expect(values["Back"]?.contains("[sound:test.wav]") == true)
        session.plan.layout?.front[0].showCaption = true
        #expect(session.content != content)
    }

    @Test func flexibleCardMissingSourceBlocksSendAndDeletionCannotBeResurrected() async throws {
        let (controller, fake, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let session = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        session.plan.layout = .init(front: [.init(source: .senseImage, blockID: UUID())], back: [.init(source: .expression)])
        #expect(session.validationMessage != nil)
        #expect(await session.send() == false)
        #expect(await fake.counts().add == 0)
        session.plan.layout = ReviewLayoutPolicy.preset(0)
        #expect(await session.save())
        let saved = try #require(session.savedReview)
        try await controller.store.removeReview(entryID: entry.id, senseID: sense.id, cardID: try #require(session.cardID), expected: saved)
        #expect(await session.save() == false)
        #expect(controller.store.entries.first?.senses.first?.reviewCards?.isEmpty == true)
    }

    @Test func flexibleBatchCountsCardsAndSendsEachOnce() async throws {
        let (controller, fake, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        for _ in 0..<2 {
            let session = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
            #expect(await session.save())
        }
        let batch = AnkiReviewBatchSession(controller: controller, selections: [.init(entryID: entry.id, senseID: sense.id)], flexible: true)
        #expect(batch.items.count == 2)
        batch.start(); await batch.work?.value
        #expect(batch.completeCount == 2)
        #expect(await fake.counts().add == 2)
        batch.start(); await batch.work?.value
        #expect(await fake.counts().add == 2)
    }
}

extension AnkiReviewTests {
    @Test func flexibleTemplatesKeepCardImagesInBackupAndReleaseOnlyAfterLastOwner() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let notebook = directory.appendingPathComponent("notebook.sqlite")
        let (controller, _, defaults, name) = try await fixture(url: notebook)
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let image = try await controller.store.prepareImage(VocabularyImageTestFixture.png())
        let session = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        session.plan.layout = .init(front: [.init(source: .custom, content: [.init(content: .image(image.reference, caption: "A clue"))])],
            back: [.init(source: .expression)])
        session.importedImages = [image.reference.filename: image.data]
        #expect(await session.save())
        let template = ReviewLayoutTemplate(name: "Picture", layout: ReviewLayoutPolicy.portable(try #require(session.plan.layout)))
        try await controller.store.saveTemplate(template)
        try await controller.store.removeReview(entryID: entry.id, senseID: sense.id, cardID: try #require(session.cardID),
            expected: try #require(session.savedReview))
        #expect(await controller.store.image(image.reference) == image.data)
        let backup = directory.appendingPathComponent("backup.lingrove")
        await controller.store.backup(to: backup)
        let saved = try JSONDecoder().decode(VocabularyBackup.self, from: Data(contentsOf: backup))
        #expect(saved.images[image.reference.filename] == image.data)
        #expect(saved.document.reviewTemplates?.count == 1)
        let restored = VocabularyArchive(url: directory.appendingPathComponent("restored.json"))
        let snapshot = try await restored.restore(from: backup)
        #expect(snapshot.document.reviewTemplates == [template])
        #expect(try await restored.image(image.reference) == image.data)
        try await controller.store.removeTemplate(template.id)
        #expect(await controller.store.image(image.reference) == nil)
    }

    @Test func flexibleAudioExportAndProfileGuardUseTheSameTransaction() async throws {
        let exporter = ReviewFakeSpeechExporter()
        let (controller, fake, defaults, name) = try await fixture(speech: exporter)
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let session = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        session.plan.layout?.back.append(.init(source: .expressionAudio))
        #expect(session.plan.audioKinds == [.expression])
        await session.load(); #expect(await session.send(), Comment(rawValue: session.message ?? ""))
        let note = try #require(session.savedReview?.activeBinding?.noteID)
        #expect(await fake.values(note)?["Front"]?.contains("[sound:") == false)
        #expect(await fake.values(note)?["Back"]?.contains("[sound:") == true)
        #expect(exporter.exports == 1)
        #expect(await session.send(), Comment(rawValue: session.message ?? ""))
        #expect(exporter.exports == 1)
        let other = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        other.plan.layout?.back.append(.init(source: .expressionAudio))
        await fake.switchProfileAfterNextMedia("Other profile")
        #expect(await other.send() == false)
        #expect(await fake.counts().add == 1)
    }

    @Test func flexibleTemplatesBindToDestinationAndSourceEditsMarkOnlyAffectedCards() async throws {
        let (controller, _, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let session = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        await session.load(); #expect(await session.send(), Comment(rawValue: session.message ?? ""))
        let original = try #require(controller.store.entries.first)
        var edited = original; edited.senses[0].meaning = "Updated meaning"; edited.senses[0].meaningOrigin = .user
        #expect(await controller.store.update(edited, basedOn: original))
        #expect(controller.isSynchronized(edited, edited.senses[0], cardID: session.cardID) == false)
        let layout = ReviewLayout(front: [.init(source: .senseImage, blockID: UUID())], back: [.init(source: .expression)])
        let portable = ReviewLayoutPolicy.portable(layout)
        #expect(portable.front[0].blockID == nil)
        #expect(portable.front[0].id != layout.front[0].id)
        #expect(ReviewLayoutPolicy.applying(portable, to: sense).front[0].blockID == nil)
    }
}

extension AnkiReviewTests {
    @Test func flexibleCardFailuresAreIsolatedAndUnsafeTemplateIsRejected() async throws {
        let (controller, fake, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let first = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        await first.load(); #expect(await first.send(), Comment(rawValue: first.message ?? ""))
        let second = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        await second.load(); await fake.failOneAdd(); #expect(await second.send() == false)
        let current = try #require(controller.store.entries.first), live = try #require(current.senses.first)
        #expect(controller.isSynchronized(current, live, cardID: first.cardID))
        #expect(controller.status(current, live, cardID: first.cardID) == String(localized: "Synced", table: "Vocabulary"))
        await fake.unsafeFlexibleTemplate()
        #expect(await second.send() == false)
        #expect(await fake.counts().add == 1)
    }

    @Test func savingTemplateDoesNotCommitTheOpenCardDraft() async throws {
        let (controller, _, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let session = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        let image = try await controller.store.prepareImage(VocabularyImageTestFixture.png())
        session.plan.layout?.front = [.init(source: .custom, content: [.init(content: .image(image.reference, caption: ""))])]
        try await controller.store.saveTemplate(.init(name: "Reusable", layout: ReviewLayoutPolicy.portable(try #require(session.plan.layout))),
            importedImages: [image.reference.filename: image.data])
        #expect(controller.store.entries.first?.senses.first?.reviewCards?.isEmpty != false)
        #expect(await controller.store.image(image.reference) == image.data)
        #expect(controller.store.reviewTemplates.count == 1)
    }
}

extension AnkiReviewTests {
    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_UI_FLEXIBLE_REVIEW"] == "1"))
    func nativeFlexibleReviewWorkflow() async throws {
        let (fixture, fake, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let controller = AnkiReviewController(settings: fixture.settings, store: fixture.store, client: fake, speech: speech, activateAnki: {})
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let image = try await controller.store.prepareImage(VocabularyImageTestFixture.png(width: 240, height: 120))
        let session = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        session.plan.name = "Image recall"
        session.plan.layout = .init(front: [.init(source: .custom, content: [.init(content: .image(image.reference, caption: "A blue visual clue"))])],
            back: [.init(source: .expression), .init(source: .meaning)])
        session.importedImages = [image.reference.filename: image.data]
        #expect(await session.save())
        let host = NSHostingView(rootView: VocabularyNotebookView(store: controller.store, speech: speech,
            selectedID: entry.id, review: controller))
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 1100, height: 820),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.title = "Lingrove flexible cards acceptance"; window.level = .floating; window.center()
        window.makeKeyAndOrderFront(nil)
        defer { speech.shutdown(); window.close() }
        for _ in 0..<480 {
            if let done = LingroveCompatibility.processEnvironment["LINGROVE_UI_FLEXIBLE_DONE"], FileManager.default.fileExists(atPath: done) { break }
            try await Task.sleep(for: .seconds(1))
        }
        #expect(controller.store.entries.first?.senses.first?.reviewCards?.count == 2)
        #expect(controller.store.reviewTemplates.count == 1)
        #expect(await fake.counts().add == 1)
    }

    @Test(.enabled(if: LingroveCompatibility.processEnvironment["LINGROVE_ANKI_ACCEPTANCE_URL"] != nil))
    func realAnkiFlexibleCardsRenderImagesAndKeepCardIdentityOnLayoutEdits() async throws {
        let (fixture, _, defaults, name) = try await fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        fixture.settings.address = try #require(LingroveCompatibility.processEnvironment["LINGROVE_ANKI_ACCEPTANCE_URL"])
        let controller = AnkiReviewController(settings: fixture.settings, store: fixture.store, client: AnkiConnectClient(),
            speech: ReviewFakeSpeechExporter(), activateAnki: {})
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let image = try await controller.store.prepareImage(VocabularyImageTestFixture.png())
        let first = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        first.plan.layout = .init(front: [.init(source: .custom, content: [.init(content: .image(image.reference, caption: ""))])],
            back: [.init(source: .expression), .init(source: .meaning), .init(source: .expressionAudio)])
        first.importedImages = [image.reference.filename: image.data]
        await first.load(); #expect(await first.send(), Comment(rawValue: first.message ?? ""))
        let binding = try #require(first.savedReview?.activeBinding), noteID = try #require(binding.noteID)
        let connection = try controller.settings.connection()
        let cards = try #require(try await controller.call("findCards", ["query": .string("nid:\(noteID)")], connection).array)
        #expect(cards.count == 1)
        let before = try await controller.call("cardsInfo", ["cards": .array(cards)], connection)
        let question = try #require(before.array?.first?.object?["question"]?.string)
        #expect(question.contains("<img")); #expect(!question.contains("银行")); #expect(!question.contains("[sound:"))
        first.plan.layout?.back.append(.init(source: .custom, content: [.init(content: .text(.init(text: "A new personal hint")))]))
        #expect(await first.send(), Comment(rawValue: first.message ?? ""))
        let after = try await controller.call("cardsInfo", ["cards": .array(cards)], connection)
        for (old, new) in zip(try #require(before.array), try #require(after.array)) {
            for key in ["cardId", "due", "interval", "reps", "lapses"] { #expect(old.object?[key] == new.object?[key]) }
        }
        #expect(after.array?.first?.object?["answer"]?.string?.contains("A new personal hint") == true)
        let second = AnkiReviewSession(controller: controller, entry: entry, sense: sense, cardID: UUID())
        await second.load(); #expect(await second.send(), Comment(rawValue: second.message ?? ""))
        #expect(second.savedReview?.activeBinding?.noteID != noteID)
    }
}

extension AnkiReviewTests {
    @Test func backupIncludesEveryAcceptedRetainedReviewLayout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (controller, _, defaults, name) = try await fixture(url: directory.appendingPathComponent("notebook.sqlite"))
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(controller.store.entries.first), sense = try #require(entry.senses.first)
        let first = try await controller.store.prepareImage(VocabularyImageTestFixture.png(width: 40, height: 20))
        let second = try await controller.store.prepareImage(VocabularyImageTestFixture.png(width: 80, height: 20))
        func layout(_ image: VocabularyImageReference) -> ReviewLayout {
            .init(front: [.init(source: .custom, content: [.init(content: .image(image, caption: ""))])], back: [.init(source: .expression)])
        }
        let review = VocabularyReview(plan: ReviewPlan(layout: layout(first.reference)),
            preservedPlans: [ReviewPlan(layout: layout(second.reference))])
        try await controller.store.saveReview(entryID: entry.id, senseID: sense.id, value: review, expected: nil,
            importedImages: [first.reference.filename: first.data, second.reference.filename: second.data])
        let file = directory.appendingPathComponent("backup.lingrove")
        await controller.store.backup(to: file)
        let backup = try JSONDecoder().decode(VocabularyBackup.self, from: Data(contentsOf: file))
        #expect(backup.images.count == 2)
        let restored = VocabularyArchive(url: directory.appendingPathComponent("restored.json"))
        _ = try await restored.restore(from: file)
        #expect(try await restored.image(first.reference) == first.data)
        #expect(try await restored.image(second.reference) == second.data)
    }
}
