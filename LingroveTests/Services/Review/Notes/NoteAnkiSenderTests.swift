import Foundation
import LingroveNotebook
import LingroveNotebookEngine
import Testing
@testable import Lingrove

@Suite(.serialized) @MainActor
struct NoteAnkiSenderTests {
    @Test func lostCreateReplyRecoversIdentityWithoutBuiltInEnrollment() async throws {
        try await withFixture { f, fake, controller, material, scope in
            let sender = NoteAnkiSender(controller: controller, io: controller.noteIO!)
            await fake.lose("addNote")
            await #expect(throws: (any Error).self) { try await sender.send(material, scope: scope, deck: "Default") }
            _ = try await sender.send(material, scope: scope, deck: "Default")
            #expect(await fake.count() == 1)
            #expect(await fake.fields()["Meaning"] == material.sense.meaning)
            #expect(try f.repository.engine.loadLingroveNotebookReviewSnapshot(scope: material.scope).groups.isEmpty)
            var source = material.scope.document
            source.entries[0].senses[0].meaning = "Updated source"
            let updated = try f.repository.engine.saveLingroveNotebook(source, basedOn: material.scope)
            let next = try await controller.noteIO!.material(selection: .init(entryID: material.entry.id, senseID: material.sense.id),
                type: material.type, scope: updated, preparing: true)
            _ = try await sender.send(next, scope: scope, deck: "Default")
            #expect(await fake.fields()["Meaning"] == "Updated source")
            #expect(try f.repository.engine.loadLingroveNotebookReviewSnapshot(scope: updated).groups.isEmpty)
        }
    }
    @Test func modelRetryAndFieldRenamePreserveCardsAndManualChanges() async throws {
        try await withFixture { f, fake, controller, material, scope in
            let sender = NoteAnkiSender(controller: controller, io: controller.noteIO!)
            _ = try await sender.send(material, scope: scope, deck: "Default")
            let cards = await fake.cardIDs()
            await fake.edit("Meaning", "My Anki wording")
            var type = material.type; type.revision += 1; type.css += "\n.card{padding:36px}"
            let index = try #require(type.fields.firstIndex { $0.name == "Meaning" }); type.fields[index].name = "Definition"
            type.templates[0].back = type.templates[0].back.replacingOccurrences(of: "{{Meaning}}", with: "{{Definition}}")
            try f.repository.engine.saveReviewNoteType(type, expected: material.type, scope: material.scope)
            let next = try await controller.noteIO!.material(selection: .init(entryID: material.entry.id, senseID: material.sense.id),
                type: type, scope: material.scope, preparing: true)
            await fake.lose("modelFieldRename")
            await #expect(throws: (any Error).self) { try await sender.send(next, scope: scope, deck: "Default") }
            _ = try await sender.send(next, scope: scope, deck: "Default")
            #expect(await fake.cardIDs() == cards)
            #expect(await fake.fields()["Definition"] == "My Anki wording")
            await fake.customizeCSS()
            await #expect(throws: (any Error).self) { try await sender.send(next, scope: scope, deck: "Default") }
            #expect(await fake.count() == 1)
        }
    }
    @Test func disabledTemplatesSuspendWithoutDeletingCards() async throws {
        try await withFixture { f, fake, controller, material, scope in
            let sender = NoteAnkiSender(controller: controller, io: controller.noteIO!)
            _ = try await sender.send(material, scope: scope, deck: "Default")
            let firstCards = await fake.cardIDs()
            let secondSelection = try await f.seed("port")
            let saved = try f.repository.snapshot()
            let second = try await controller.noteIO!.material(selection: secondSelection, type: material.type, scope: saved, preparing: true)
            _ = try await sender.send(second, scope: scope, deck: "Default")
            let cards = await fake.cardIDs()
            await fake.suspendManually(cards.subtracting(firstCards))
            var disabled = material.type; disabled.revision += 1; disabled.templates[0].enabled = false
            try f.repository.engine.saveReviewNoteType(disabled, expected: material.type, scope: saved)
            let next = try await controller.noteIO!.material(selection: .init(entryID: material.entry.id, senseID: material.sense.id), type: disabled, scope: saved, preparing: true)
            _ = try await sender.send(next, scope: scope, deck: "Default")
            #expect(await fake.allSuspended())
            #expect(await fake.cardIDs() == cards)
            var enabled = disabled; enabled.revision += 1; enabled.templates[0].enabled = true
            try f.repository.engine.saveReviewNoteType(enabled, expected: disabled, scope: saved)
            let restored = try await controller.noteIO!.material(selection: .init(entryID: material.entry.id, senseID: material.sense.id), type: enabled, scope: saved, preparing: true)
            _ = try await sender.send(restored, scope: scope, deck: "Default")
            #expect(await fake.suspendedCount() == 1, "Anki's prior manual suspension must survive re-enabling the shared template")
        }
    }
    @Test func concurrentFieldEditsAndStaleChoicesDoNotOverwriteAnki() async throws {
        try await withFixture { f, fake, controller, material, scope in
            let sender = NoteAnkiSender(controller: controller, io: controller.noteIO!)
            _ = try await sender.send(material, scope: scope, deck: "Default")
            await fake.edit("Meaning", "Anki edit")
            var document = material.scope.document; document.entries[0].senses[0].meaning = "Corpus edit"
            let saved = try f.repository.engine.saveLingroveNotebook(document, basedOn: material.scope)
            let next = try await controller.noteIO!.material(selection: .init(entryID: material.entry.id, senseID: material.sense.id),
                type: material.type, scope: saved, preparing: true)
            let conflict = try await sender.send(next, scope: scope, deck: "Default")
            #expect(conflict.conflicts == ["Meaning"])
            await fake.edit("Meaning", "Later Anki edit")
            let stale = try await sender.send(next, scope: scope, deck: "Default", choices: ["Meaning": false], expectedRemote: conflict.remote)
            #expect(stale.conflicts == ["Meaning"])
            #expect(await fake.fields()["Meaning"] == "Later Anki edit")
            let accepted = try await sender.send(next, scope: scope, deck: "Default", choices: ["Meaning": true], expectedRemote: stale.remote)
            #expect(accepted.conflicts.isEmpty)
            #expect(await fake.fields()["Meaning"] == "Later Anki edit")
        }
    }

    @Test func previewDoesNotPrepareOrEnrollANote() async throws {
        let f = try NotebookWorkspaceFixture()
        do {
            let selection = try await f.seed(), fake = NoteAnkiFake()
            let controller = AnkiReviewController(settings: f.anki.settings, store: f.store, repository: f.repository, client: fake, activateAnki: {})
            let session = NoteAnkiSession(controller: controller, selection: selection)
            await session.load()
            #expect(session.material != nil && session.message == nil)
            let saved = try f.repository.snapshot()
            #expect(try ReviewNoteStore(core: f.repository.engine.core).notes(scope: saved).isEmpty)
            #expect(try f.repository.engine.loadLingroveNotebookReviewSnapshot(scope: saved).groups.isEmpty)
            #expect(await fake.count() == 0)
            await f.cleanUp()
        } catch { await f.cleanUp(); throw error }
    }

    @Test func batchUsesOneSharedTypeWithoutLegacyCardPreparation() async throws {
        let f = try NotebookWorkspaceFixture()
        do {
            let first = try await f.seed(), second = try await f.seed("port"), fake = NoteAnkiFake()
            let controller = AnkiReviewController(settings: f.anki.settings, store: f.store, repository: f.repository, client: fake, activateAnki: {})
            let batch = AnkiReviewBatchSession(controller: controller, selections: [first, second, first], flexible: true)
            #expect(batch.items.count == 2 && batch.emptySenseCount == 0)
            batch.start(); await batch.work?.value
            #expect(batch.completeCount == 2 && batch.message == nil)
            #expect(await fake.count() == 2)
            #expect(await fake.modelCount() == 1)
            let saved = try f.repository.snapshot()
            #expect(try f.repository.engine.loadLingroveNotebookReviewSnapshot(scope: saved).groups.isEmpty)
            #expect(saved.document.entries.allSatisfy { $0.senses.allSatisfy { $0.reviewCards?.isEmpty != false } })
            await f.cleanUp()
        } catch { await f.cleanUp(); throw error }
    }

    @Test func newlyAddedFieldsDoNotEraseUnacknowledgedAnkiValues() {
        let receipt = NoteAnkiJournal.Note(localFields: ["Expression": "harbor"], remoteFields: ["Expression": "harbor"])
        let result = NoteAnkiFieldMerge.resolve(desired: ["Expression": "harbor", "Hint": ""],
            remote: ["Expression": "harbor", "Hint": "My hint"], receipt: receipt, choices: [:])
        #expect(result.fields["Hint"] == "My hint" && result.conflicts.isEmpty)
        let conflict = NoteAnkiFieldMerge.resolve(desired: ["Hint": "Source hint"], remote: ["Hint": "My hint"], receipt: receipt, choices: [:])
        #expect(conflict.conflicts == ["Hint"])
    }

    private func withFixture(_ body: (NotebookWorkspaceFixture, NoteAnkiFake, AnkiReviewController, NoteAnkiIO.Material, ReviewOperationScope) async throws -> Void) async throws {
        let f = try NotebookWorkspaceFixture()
        do {
            let selection = try await f.seed(), fake = NoteAnkiFake()
            let controller = AnkiReviewController(settings: f.anki.settings, store: f.store, repository: f.repository, client: fake, activateAnki: {})
            let scope = try f.repository.snapshot()
            let material = try await controller.noteIO!.material(selection: selection, type: ReviewNoteDefaults.type, scope: scope, preparing: true)
            try await body(f, fake, controller, material, controller.operationScope())
            await f.cleanUp()
        } catch { await f.cleanUp(); throw error }
    }
}
