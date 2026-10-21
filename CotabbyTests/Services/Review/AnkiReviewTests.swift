import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Cotabby

/// An isolated stateful Anki implementation exercises the complete add/update/recovery protocol.
/// It simulates a committed write with a lost acknowledgement, which a stateless mock misses.
actor ReviewFakeAnki: AnkiConnecting {
    var profileName = "Acceptance"
    var decks = ["Default", "Other"]
    func setDecks(_ value: [String]) { decks = value }
    var notes: [Int64: [String: String]] = [:]
    var noteModels: [Int64: String] = [:]
    var noteDecks: [Int64: String] = [:]
    var nextID: Int64 = 1_000
    var addCount = 0
    var updateCount = 0
    var loseAddReply = false
    var holdAdd: CheckedContinuation<Void, Never>?
    var pauseAdd = false
    var customFields: [String: [String]] = [:]
    var flexibleTemplates = ReviewLayoutPolicy.templates
    func unsafeFlexibleTemplate() { flexibleTemplates["Card"] = .object(["Front": .string("{{Back}}"), "Back": .string("{{Back}}")]) }
    var templates = AnkiNoteTemplate.templates
    var css = AnkiNoteTemplate.css
    var media: [String: Data] = [:]
    var profileAfterMedia: String?
    var templateReadCount = 0
    var profileAtTemplateRead: Int?
    func switchProfileOnSecondTemplateRead() { templateReadCount = 0; profileAtTemplateRead = 2 }
    func switchProfileAfterNextMedia(_ name: String) { profileAfterMedia = name }
    var failNextAdd = false
    var navigationDeck: String?
    var profileAfterMetadata: String?
    var metadataHook: (@MainActor @Sendable () -> Void)?
    func afterNextMetadata(_ hook: @escaping @MainActor @Sendable () -> Void) { metadataHook = hook }
    func sentDecks() -> [String] { Array(noteDecks.values) }
    func switchProfileAfterNextMetadata(_ value: String) { profileAfterMetadata = value }
    func failOneAdd() { failNextAdd = true }
    func mediaCount() -> Int { media.count }
    func removeMedia() { media = [:] }
    func templateSnapshot() -> [String: AnkiValue] { templates }
    func setLegacyTemplate() {
        templates = AnkiNoteTemplate.legacyTemplates; css = AnkiNoteTemplate.legacyCSS
        customFields[AnkiReviewPolicy.presetName] = ReviewField.allCases.filter {
            ![.expressionAudio, .sentenceAudio].contains($0)
        }.map(\.rawValue)
    }
    func customizeTemplate() { templates["Recognition"] = .object(["Front": .string("custom"), "Back": .string("custom")]) }

    func setFields(_ fields: [String], for model: String) { customFields[model] = fields }
    func loseNextAddReply() { loseAddReply = true }
    func setProfile(_ name: String) { profileName = name }
    func edit(_ id: Int64, field: String, text: String) { notes[id]?[field] = text }
    func delete(_ id: Int64) { notes[id] = nil }
    func values(_ id: Int64) -> [String: String]? { notes[id] }
    func counts() -> (add: Int, update: Int) { (addCount, updateCount) }
    // The fixture dispatches the independent Anki API actions, just like the external server.
    // swiftlint:disable:next cyclomatic_complexity
    func perform(_ action: String, params: [String: AnkiValue], connection: AnkiConnection) async throws -> AnkiValue {
        switch action {
        case "getActiveProfile": return .string(profileName)
        case "deckNames": return .list(decks)
        case "modelNames": return .list([AnkiReviewPolicy.presetName] + customFields.keys.sorted())
        case "modelFieldNames":
            if let value = profileAfterMetadata { profileName = value; profileAfterMetadata = nil }
            if let hook = metadataHook { metadataHook = nil; await hook() }
            return .list(customFields[params["modelName"]?.string ?? ""] ?? ReviewField.allCases.map(\.rawValue))
        case "findNotes":
            let query = params["query"]?.string ?? ""
            return .array(notes.compactMap { id, fields in
                query.contains(fields["LingroveID"] ?? "never-match") ? .number(Double(id)) : nil
            })
        case "notesInfo":
            return .array((params["notes"]?.array ?? []).map { value in
                guard let id = value.integer, let fields = notes[id] else { return .object([:]) }
                return .object(["noteId": .number(Double(id)), "modelName": .string(noteModels[id] ?? AnkiReviewPolicy.presetName),
                    "fields": .object(fields.mapValues { .object(["value": .string($0)]) })])
            })
        case "addNote":
            if failNextAdd { failNextAdd = false; throw URLError(.cannotConnectToHost) }
            let note = params["note"]?.object ?? [:]
            nextID += 1; let id = nextID
            notes[id] = note["fields"]?.object?.compactMapValues(\.string) ?? [:]; addCount += 1
            noteModels[id] = note["modelName"]?.string
            noteDecks[id] = note["deckName"]?.string
            if pauseAdd { await withCheckedContinuation { holdAdd = $0 } }
            if loseAddReply { loseAddReply = false; throw URLError(.networkConnectionLost) }
            return .number(Double(id))
        case "updateNoteFields":
            guard let note = params["note"]?.object, let id = note["id"]?.integer else { return .null }
            for (key, value) in note["fields"]?.object ?? [:] { notes[id]?[key] = value.string }
            updateCount += 1; return .null
        case "modelTemplates":
            templateReadCount += 1
            if templateReadCount == profileAtTemplateRead { profileName = "Changed profile" }
            return .object(params["modelName"]?.string == ReviewLayoutPolicy.model ? flexibleTemplates : templates)
        case "modelStyling": return .object(["css": .string(css)])
        case "modelFieldAdd":
            let model = params["modelName"]?.string ?? ""
            customFields[model, default: []].append(params["fieldName"]?.string ?? "")
            return .null
        case "updateModelTemplates":
            templates = params["model"]?.object?["templates"]?.object ?? [:]; return .null
        case "updateModelStyling": css = params["model"]?.object?["css"]?.string ?? ""; return .null
        case "storeMediaFile":
            let filename = params["filename"]?.string ?? ""
            media[filename] = Data(base64Encoded: params["data"]?.string ?? "")
            if let profileAfterMedia { profileName = profileAfterMedia; self.profileAfterMedia = nil }
            return .string(filename)
        case "getMediaFilesNames": return .list(media.keys.filter { $0 == params["pattern"]?.string })
        case "findCards": return .array([.number(10)])
        case "cardsInfo": return .array([.object(["deckName": .string("Other")])])
        case "guiDeckOverview": navigationDeck = params["name"]?.string; return .bool(true)
        case "createModel":
            customFields[params["modelName"]?.string ?? ""] = params["inOrderFields"]?.array?.compactMap(\.string) ?? []
            return .null
        case "guiBrowse": return .null
        default: throw AnkiReviewError.message("Unexpected fixture action: " + action)
        }
    }
}

@Suite(.serialized)
@MainActor
struct AnkiReviewTests {
    // Four shared fixture dependencies keep each transaction test focused on observable effects.
    // swiftlint:disable:next large_tuple
    func fixture(url: URL? = nil, speech: (any SpeechExporting)? = nil) async throws -> (AnkiReviewController, ReviewFakeAnki, UserDefaults, String) {
        let name = "test.anki-review." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let store = VocabularyStore(archive: VocabularyArchive(url: url))
        for (text, meaning) in [("The bank opened early.", "银行"), ("We sat beside the bank.", "河岸")] {
            var example = try #require(VocabularyPolicy.example(text: text,
                ranges: [(text as NSString).range(of: "bank")], language: .english))
            example.meaning = meaning
            await store.save(.init(expression: "bank", dictionaryForm: "bank", language: .english, kind: .word, example: example))
        }
        let fake = ReviewFakeAnki()
        let settings = AnkiReviewSettings(defaults: defaults, credentials: AnkiCredentialStore(service: nil))
        return (AnkiReviewController(settings: settings, store: store, client: fake, speech: speech, activateAnki: {}), fake, defaults, name)
    }
    func session(_ controller: AnkiReviewController, index: Int = 0) throws -> AnkiReviewSession {
        let entry = try #require(controller.store.entries.first)
        return AnkiReviewSession(controller: controller, entry: entry, sense: entry.senses[index])
    }

    @Test func twoSensesHaveSeparateNotesAndUpdatesKeepTheirIDs() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        #expect(try await session(controller).send())
        #expect(try await session(controller, index: 1).send())
        let entry = try #require(controller.store.entries.first)
        let first = try #require(entry.senses[0].review?.activeBinding?.noteID)
        let second = try #require(entry.senses[1].review?.activeBinding?.noteID)
        #expect(first != second)
        let edit = try session(controller); edit.plan.answer = "a financial institution"
        #expect(await edit.send())
        #expect(controller.store.entries[0].senses[0].review?.activeBinding?.noteID == first)
        #expect(await fake.values(first)?["Meaning"] == "a financial institution")
        #expect(await fake.values(second)?["Meaning"] == "河岸")
        #expect(await fake.counts().add == 2)
    }

    @Test func committedAddWithLostReplyRecoversAfterMergeAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.json")
        let (controller, fake, defaults, name) = try await fixture(url: url)
        defer { defaults.removePersistentDomain(forName: name) }
        await fake.loseNextAddReply()
        let sending = try session(controller)
        #expect(!(await sending.send()))
        let old = controller.store.entries[0]
        let intent = try #require(old.senses[0].review?.activeBinding)
        #expect(intent.noteID == nil)
        sending.deck = "Other"
        #expect(await sending.save())
        // Reconstruct the archive actor and store, rather than only reopening a sheet. Recovery
        // depends on the pending identity having reached disk before the lost acknowledgement.
        let reloaded = VocabularyStore(archive: VocabularyArchive(url: url)); await reloaded.load()
        #expect(reloaded.entries[0].senses[0].review?.activeBinding?.id == intent.id)
        #expect(reloaded.entries[0].senses[0].review?.activeBinding?.deck == "Other")
        #expect(reloaded.entries[0].senses[0].review?.plan.deck == "Other")
        #expect(await reloaded.mergeSenses(entryID: old.id, source: old.senses[0].id, target: old.senses[1].id))
        let recovered = AnkiReviewController(settings: controller.settings, store: reloaded, client: fake)
        let reopened = try session(recovered)
        #expect(await reopened.send())
        #expect(await fake.counts().add == 1)
        #expect(reloaded.entries[0].senses[0].review?.activeBinding?.originSenseID == old.senses[0].id)
    }

    @Test func remoteEditsRequireChoiceAndCanRemainAsReviewOnlyOverrides() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        #expect(try await session(controller).send())
        let id = try #require(controller.store.entries[0].senses[0].review?.activeBinding?.noteID)
        await fake.edit(id, field: "Meaning", text: "A user-authored Anki answer")
        let edit = try session(controller); edit.plan.includeNotes = true
        #expect(!(await edit.send()))
        #expect(edit.conflicts.map(\.id) == ["Meaning"])
        #expect(await fake.counts().update == 0)
        edit.keepRemote["Meaning"] = true
        #expect(await edit.send())
        #expect(controller.store.entries[0].senses[0].examples[0].meaning == "银行")
        #expect(controller.store.entries[0].senses[0].review?.plan.fieldOverrides["Meaning"] == "A user-authored Anki answer")
        #expect(try await session(controller).send())
        #expect(await fake.values(id)?["Meaning"] == "A user-authored Anki answer")
    }

    @Test func missingNoteNeedsExplicitRecreationAndWrongProfileNeverWrites() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        #expect(try await session(controller).send())
        let id = try #require(controller.store.entries[0].senses[0].review?.activeBinding?.noteID)
        await fake.setProfile("Another profile")
        #expect(!(try await session(controller).send()))
        let counts = await fake.counts()
        #expect(counts.add == 1 && counts.update == 0)
        await fake.setProfile("Acceptance"); await fake.delete(id)
        let retry = try session(controller)
        #expect(!(await retry.send()))
        #expect(retry.missingNote)
        #expect(await retry.send(recreateMissing: true))
        #expect(await fake.counts().add == 2)
    }

    @Test func movingTheRepresentativeUsageKeepsSenseHistoryAndRequiresReselection() async throws {
        let (controller, _, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        #expect(try await session(controller).send())
        let entry = controller.store.entries[0], source = entry.senses[0]
        let original = try #require(source.review?.activeBinding)
        #expect(await controller.store.moveExample(entryID: entry.id, exampleID: source.examples[0].id,
            source: source.id, target: entry.senses[1].id))
        let invalid = try session(controller)
        #expect(invalid.validationMessage != nil)
        #expect(controller.store.entries[0].senses[0].review?.activeBinding == original)
        #expect(controller.store.entries[0].senses[1].review == nil)
        invalid.plan.exampleID = nil; invalid.plan.answer = "A financial institution"
        #expect(await invalid.send())
        #expect(controller.store.entries[0].senses[0].review?.activeBinding?.noteID == original.noteID)
    }

    @Test func mergedBindingsNeedAnExplicitChoiceAndKeepBothNotes() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        #expect(try await session(controller).send()); #expect(try await session(controller, index: 1).send())
        let entry = controller.store.entries[0]
        #expect(await controller.store.mergeSenses(entryID: entry.id, source: entry.senses[0].id, target: entry.senses[1].id))
        let merged = try session(controller)
        #expect(!(await merged.send()))
        let review = try #require(controller.store.entries[0].senses[0].review)
        #expect(review.bindings.count == 2)
        merged.selectBinding(review.bindings[0].id)
        #expect(await merged.send())
        #expect(await fake.counts().add == 2)
        #expect(controller.store.entries[0].senses[0].review?.bindings.count == 2)
    }

    @Test func selectingDifferentModelsRefreshesFieldsAndProtectsExistingGapCards() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        #expect(try await session(controller).send())
        let entry = controller.store.entries[0], sense = entry.senses[0]
        let mapping: [ReviewField: String] = [.identity: "ID", .expression: "Word", .meaning: "Answer",
            .gapPrompt: "Question", .gapAnswer: "Solution"]
        let custom = AnkiNoteBinding(originSenseID: entry.senses[1].id, endpoint: "http://127.0.0.1:8765",
            profile: "Acceptance", noteID: 2_000, model: "Custom", deck: "Other", identityField: "ID",
            mapping: mapping, fields: ["ID": entry.senses[1].id.uuidString.lowercased(),
                "Question": "The [...] opened early."], syncedAt: Date())
        try await controller.store.recordAnkiBinding(entryID: entry.id, senseID: sense.id, binding: custom)
        await fake.setFields(Array(mapping.values), for: "Custom")
        let draft = try session(controller)
        draft.selectBinding(sense.review?.activeBindingID); await draft.load()
        #expect(draft.availableFields.contains("LingroveID"))
        draft.selectBinding(custom.id); await draft.load()
        #expect(draft.deck == "Other")
        #expect(draft.availableFields.contains("ID") && !draft.availableFields.contains("LingroveID"))
        #expect(draft.hasExistingCard(.gapPrompt))
        draft.plan.gap = false
        #expect(draft.validationMessage != nil)
        draft.plan.gap = true
        #expect(draft.validationMessage == nil)
        var saved = draft.plan; saved.recognition = false; saved.fieldOverrides = ["Answer": "Anki answer"]
        draft.restorePlan(saved)
        #expect(draft.plan.recognition)
        #expect(draft.plan.fieldOverrides == saved.fieldOverrides)
        #expect(draft.plan.id != saved.id)
    }

    @Test func audioIsOptInAndReusesVerifiedMediaOnLaterUpdates() async throws {
        let speech = ReviewFakeSpeechExporter()
        let (controller, fake, defaults, name) = try await fixture(speech: speech)
        defer { defaults.removePersistentDomain(forName: name) }
        let initial = try session(controller)
        #expect(speech.exports == 0)
        initial.plan.audioKinds = [.expression, .sentence]
        #expect(await initial.send())
        #expect(speech.exports == 2)
        #expect(await fake.mediaCount() == 2)
        let binding = try #require(controller.store.entries[0].senses[0].review?.activeBinding)
        let id = try #require(binding.noteID)
        #expect(binding.fields["ExpressionAudio"]?.hasPrefix("[sound:lingrove-") == true)
        #expect(try await session(controller).send())
        #expect(speech.exports == 2)
        #expect(controller.store.entries[0].senses[0].review?.activeBinding?.noteID == id)
        let regenerate = try session(controller)
        await regenerate.prepareAudio(.expression, audition: false, force: true)
        #expect(await regenerate.send())
        #expect(speech.exports == 3)
        #expect(await fake.mediaCount() == 3)
        #expect(controller.store.entries[0].senses[0].review?.activeBinding?.fields["ExpressionAudio"] != binding.fields["ExpressionAudio"])
    }

    @Test func batchContinuesAfterFailureAndOnlyRetriesUnsuccessfulSenses() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let entry = controller.store.entries[0]
        let batch = AnkiReviewBatchSession(controller: controller, selections: entry.senses.map {
            .init(entryID: entry.id, senseID: $0.id)
        })
        await fake.failOneAdd()
        batch.start(); await batch.work?.value
        #expect(batch.items.map(\.status) == [.failed, .synced])
        #expect(await fake.counts().add == 1)
        batch.start(); await batch.work?.value
        #expect(batch.items.allSatisfy { $0.status == .synced })
        #expect(await fake.counts().add == 2)
    }

    @Test func batchResolvesMergedAliasesWithoutDuplicatingNotes() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let entry = controller.store.entries[0]
        let batch = AnkiReviewBatchSession(controller: controller, selections: entry.senses.map {
            .init(entryID: entry.id, senseID: $0.id)
        })
        #expect(await controller.store.mergeSenses(entryID: entry.id, source: entry.senses[0].id, target: entry.senses[1].id))
        batch.start(); await batch.work?.value
        #expect(batch.items.map(\.status) == [.synced, .skipped])
        #expect(await fake.counts().add == 1)
    }

    @Test func templateUpgradeKeepsNoteIdentityAndRefusesCustomTemplates() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        await fake.setLegacyTemplate()
        let legacy = try session(controller); await legacy.load()
        #expect(!legacy.currentPresetTemplate)
        #expect(await legacy.send())
        let id = try #require(controller.store.entries[0].senses[0].review?.activeBinding?.noteID)
        try await controller.updatePresetTemplate()
        #expect(await fake.templateSnapshot() == AnkiNoteTemplate.templates)
        #expect(controller.store.entries[0].senses[0].review?.activeBinding?.noteID == id)
        let updated = try session(controller); await updated.load()
        #expect(updated.currentPresetTemplate)
        #expect(await updated.send())
        #expect(await fake.counts().add == 1)
        await fake.customizeTemplate()
        await #expect(throws: (any Error).self) { try await controller.updatePresetTemplate() }
    }

    @Test func reviewNavigationUsesAnkisCurrentDeckAndRejectsAnotherProfile() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        #expect(try await session(controller).send())
        let binding = try #require(controller.store.entries[0].senses[0].review?.activeBinding)
        #expect(await controller.reviewDeck(binding) == nil)
        #expect(await fake.navigationDeck == "Other")
        await fake.setProfile("Another profile")
        #expect(await controller.reviewDeck(binding) != nil)
    }

    @Test func missingAnkiMediaIsRestoredInsteadOfTrustingAnOldReceipt() async throws {
        let speech = ReviewFakeSpeechExporter()
        let (controller, fake, defaults, name) = try await fixture(speech: speech)
        defer { defaults.removePersistentDomain(forName: name) }
        let first = try session(controller); first.plan.audioKinds = [.expression]
        #expect(await first.send())
        await fake.removeMedia()
        let entry = controller.store.entries[0]
        let batch = AnkiReviewBatchSession(controller: controller, selections: [.init(entryID: entry.id, senseID: entry.senses[0].id)])
        #expect(batch.items[0].status == .verifyAudio)
        batch.start(); await batch.work?.value
        #expect(batch.items[0].status == .synced)
        #expect(speech.exports == 2)
        #expect(await fake.mediaCount() == 1)
        #expect(await fake.counts().add == 1)
    }

    @Test func cancellingPreparationKeepsASynchronizedBatchRowOutOfRetry() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let entry = controller.store.entries[0]
        let batch = AnkiReviewBatchSession(controller: controller, selections: [
            .init(entryID: entry.id, senseID: entry.senses[0].id)])
        batch.start(); await batch.work?.value
        let id = batch.items[0].id
        batch.beginPreparation(id); batch.refresh(id)
        #expect(batch.items[0].status == .synced)
        batch.start(); await batch.work?.value
        #expect(await fake.counts().add == 1)
        #expect(await fake.counts().update == 0)
    }

    @Test func batchPreparationRespectsALocalizedInitialAnkiDeck() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        await fake.setDecks(["系统默认"])
        let entry = controller.store.entries[0]
        let batch = AnkiReviewBatchSession(controller: controller, selections: entry.senses.map {
            .init(entryID: entry.id, senseID: $0.id)
        })
        batch.startApply(deck: "", cards: 1, audio: 1); await batch.work?.value
        #expect(controller.store.entries[0].senses.allSatisfy { $0.review?.plan.deck == "系统默认" })
    }

    @Test func noContextSentenceAudioFailsPreflight() async throws {
        let (controller, _, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let draft = try session(controller)
        draft.plan.exampleID = nil; draft.plan.audioKinds = [.sentence]
        #expect(draft.validationMessage != nil)
    }

    @Test func batchFreezesDefaultsWithoutOverwritingNewSettingsChoices() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let entry = controller.store.entries[0]
        let batch = AnkiReviewBatchSession(controller: controller, selections: entry.senses.map {
            .init(entryID: entry.id, senseID: $0.id)
        })
        await fake.afterNextMetadata {
            controller.settings.deck = "Other"
            controller.settings.defaultRecognition = false; controller.settings.defaultGap = true
        }
        batch.start(); await batch.work?.value
        #expect(batch.items.allSatisfy { $0.status == .synced })
        #expect(await fake.sentDecks() == ["Default", "Default"])
        #expect(controller.store.entries[0].senses.allSatisfy { $0.review?.plan.recognition == true && $0.review?.plan.gap == false })
        #expect(controller.settings.deck == "Other")
        #expect(!controller.settings.defaultRecognition && controller.settings.defaultGap)
    }

    @Test func anOpenPreparationDoesNotReplaceDefaultsChangedBeforeSend() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let draft = try session(controller)
        controller.settings.deck = "Other"
        controller.settings.defaultRecognition = false; controller.settings.defaultGap = true
        #expect(await draft.send())
        #expect(await fake.sentDecks() == ["Default"])
        #expect(controller.settings.deck == "Other")
        #expect(!controller.settings.defaultRecognition && controller.settings.defaultGap)
    }

    @Test func batchCannotFollowAProfileChangeDuringItemLoading() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let entry = controller.store.entries[0]
        let batch = AnkiReviewBatchSession(controller: controller, selections: entry.senses.map {
            .init(entryID: entry.id, senseID: $0.id)
        })
        await fake.switchProfileAfterNextMetadata("Different")
        batch.start(); await batch.work?.value
        #expect(await fake.counts().add == 0)
        #expect(controller.store.entries[0].senses.allSatisfy { $0.review == nil })
        #expect(batch.items.allSatisfy { $0.status == .failed })
    }

    @Test func cancellingBatchAudioDoesNotCreateNotesOrSendFollowingItems() async throws {
        let speech = ReviewFakeSpeechExporter(); speech.delay = .seconds(5)
        let (controller, fake, defaults, name) = try await fixture(speech: speech)
        defer { defaults.removePersistentDomain(forName: name) }
        let plan = try session(controller); plan.plan.audioKinds = [.expression]
        #expect(await plan.save())
        let entry = controller.store.entries[0]
        let batch = AnkiReviewBatchSession(controller: controller, selections: entry.senses.map {
            .init(entryID: entry.id, senseID: $0.id)
        })
        batch.start()
        while speech.exports == 0 && batch.busy { await Task.yield() }
        batch.stop(); await batch.work?.value
        #expect(await fake.counts().add == 0)
        #expect(batch.items.allSatisfy { $0.status == .cancelled })
        #expect(!batch.busy)
        #expect(controller.failures.isEmpty)
    }

    @Test func systemSpeechExportsPlayableAudioWithoutTemporaryFiles() async throws {
        let name = "test.speech-export." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let request = try speech.exportRequest(text: "Please keep me posted on the progress. This recording is for a language learning card.", language: .english)
        let audio = try await speech.exportAudio(request)
        #expect(audio.fileExtension == "wav")
        #expect(audio.data.count > 44)
        #expect(speech.activeTarget == nil)
        #expect(speech.exportToken == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COTABBY_ANKI_ACCEPTANCE_URL"] != nil))
    func realAnkiCreatesTwoCardsAndUpdatesWithoutReplacingReviewIdentity() async throws {
        let (fixture, _, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let endpoint = try #require(ProcessInfo.processInfo.environment["COTABBY_ANKI_ACCEPTANCE_URL"])
        fixture.settings.address = endpoint
        let controller = AnkiReviewController(settings: fixture.settings, store: fixture.store)
        let initial = try session(controller); initial.plan.gap = true; await initial.load()
        #expect(await initial.send())
        let first = try #require(controller.store.entries[0].senses[0].review?.activeBinding)
        let id = try #require(first.noteID)
        let connection = try controller.settings.connection()
        let note = try await controller.call("notesInfo", ["notes": .array([.number(Double(id))])], connection)
        let cards = try #require(note.array?.first?.object?["cards"]?.array)
        #expect(cards.count == 2)
        let before = try await controller.call("cardsInfo", ["cards": .array(cards)], connection)
        let edit = try session(controller); edit.plan.answer = "A financial institution"
        #expect(await edit.send())
        let after = try await controller.call("cardsInfo", ["cards": .array(cards)], connection)
        #expect(controller.store.entries[0].senses[0].review?.activeBinding?.noteID == id)
        for (old, new) in zip(try #require(before.array), try #require(after.array)) {
            for key in ["cardId", "due", "interval", "reps", "lapses"] { #expect(old.object?[key] == new.object?[key]) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COTABBY_ANKI_ACCEPTANCE_URL"] != nil))
    func realAnkiUpgradesLegacyCardsAndStoresPlayableMediaWithoutResettingHistory() async throws {
        let speech = ReviewFakeSpeechExporter()
        let (fixture, _, defaults, name) = try await fixture(speech: speech)
        defer { defaults.removePersistentDomain(forName: name) }
        fixture.settings.address = try #require(ProcessInfo.processInfo.environment["COTABBY_ANKI_ACCEPTANCE_URL"])
        let controller = AnkiReviewController(settings: fixture.settings, store: fixture.store, speech: speech, activateAnki: {})
        let first = try session(controller); first.plan.gap = true; await first.load()
        #expect(await first.send())
        let id = try #require(controller.store.entries[0].senses[0].review?.activeBinding?.noteID)
        let connection = try controller.settings.connection()
        let old = try await controller.call("notesInfo", ["notes": .array([.number(Double(id))])], connection)
        let cards = try #require(old.array?.first?.object?["cards"]?.array)
        #expect(cards.count == 2)
        let before = try await controller.call("cardsInfo", ["cards": .array(cards)], connection)
        try await controller.updatePresetTemplate()
        let second = try session(controller); await second.load()
        #expect(second.currentPresetTemplate)
        second.plan.audioKinds = [.expression, .sentence]
        let sent = await second.send()
        #expect(sent, "\(second.message ?? "No error") · conflicts: \(second.conflicts.map(\.id))")
        let review = try #require(controller.store.entries[0].senses[0].review)
        #expect(review.activeBinding?.noteID == id)
        for receipt in (review.plan.audioReceipts ?? [:]).values {
            let stored = try await controller.call("retrieveMediaFile", ["filename": .string(receipt.filename)], connection)
            let data = try #require(stored.string.flatMap { Data(base64Encoded: $0) })
            #expect(SpeechExportPolicy.validFilename(receipt.filename))
            #expect(data[20] == 1 && data[34] == 16)
        }
        let after = try await controller.call("cardsInfo", ["cards": .array(cards)], connection)
        for (old, new) in zip(try #require(before.array), try #require(after.array)) {
            for key in ["cardId", "due", "interval", "reps", "lapses"] { #expect(old.object?[key] == new.object?[key]) }
            if let question = new.object?["question"]?.string, question.contains("___") {
                #expect(!question.contains("银行"))
                #expect(!question.contains("[sound:"))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COTABBY_UI_REVIEW_SECOND_ACCEPTANCE"] == "1"))
    func nativeSecondReviewWorkflow() async throws {
        let (fixture, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let controller = AnkiReviewController(settings: fixture.settings, store: fixture.store, client: fake,
            speech: speech, activateAnki: {})
        let entry = try #require(controller.store.entries.first)
        let host = NSHostingView(rootView: VocabularyNotebookView(store: controller.store, speech: speech,
            selectedID: entry.id, review: controller))
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.title = "Lingrove batch/audio acceptance"; window.level = .floating; window.center()
        window.makeKeyAndOrderFront(nil)
        defer { speech.shutdown(); window.close() }
        for _ in 0..<4 { try await Task.sleep(for: .seconds(45)) }
        #expect(await fake.counts().add == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["COTABBY_UI_REVIEW_ACCEPTANCE"] == "1"))
    func nativeReviewWorkflowUsesAnIsolatedNotebookAndServer() async throws {
        let (controller, fake, defaults, name) = try await fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(controller.store.entries.first)
        let speech = LearningSpeechController(settings: LearningSpeechSettings(defaults: defaults))
        let host = NSHostingView(rootView: VocabularyNotebookView(store: controller.store, speech: speech,
            selectedID: entry.id, review: controller))
        let window = NSWindow(contentRect: .init(x: 120, y: 150, width: 1040, height: 740),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.title = "Lingrove Anki review acceptance"; window.level = .floating
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<2 { try await Task.sleep(for: .seconds(45)) }
        #expect(await fake.counts().add == 1)
    }
}

/// Deterministic in-memory audio makes media identity, opt-in and regeneration observable.
@MainActor
final class ReviewFakeSpeechExporter: SpeechExporting {
    var exports = 0
    var delay: Duration = .zero
    var exportConfigurationID: String { "fixture" }
    func exportRequest(text: String, language: LearningLanguage, context: String?) throws -> SpeechExportRequest {
        .init(text: text, language: language, fingerprint: SpeechExportPolicy.digest(Data(text.utf8)), source: .system(voiceID: "fixture"))
    }
    func exportAudio(_ request: SpeechExportRequest) async throws -> SpeechExportAudio {
        try Task.checkCancellation(); exports += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        var value = Float(exports) / 100
        let sample = withUnsafeBytes(of: &value) { Data($0) }
        let data = (0..<2400).reduce(into: Data()) { result, _ in result.append(sample) }
        return try SpeechExportPolicy.wav(data, sampleRate: 24_000)
    }
    func audition(_ audio: SpeechExportAudio, ownerID: UUID, language: LearningLanguage) throws {}
    func stop(ownerID: UUID) {}
}
