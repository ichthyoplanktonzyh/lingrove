@testable import LingroveNotebookStorage
import LingroveNotebook
import LingroveNotebookEngine
import Foundation
import Testing
@testable import Lingrove

/// Tests use the real bundled executable, passive mailbox server, shared UI store and private
/// SQLite file. A fake containing bundle chooses a disposable mailbox; --no-launch guarantees
/// these processes cannot launch or write the user's Dev/production notebook.
@Suite(.serialized)
@MainActor
struct VocabularyCLITests {
    @Test func batchReadsReturnOrderedCompleteRecordsFromOneScopeWithoutWrites() async throws {
        let fixture = try await Fixture()
        do {
            let png = fixture.directory.appendingPathComponent("image.png")
            try VocabularyImageTestFixture.png().write(to: png)
            #expect(try await fixture.apply(batch("batch-read-seed", [
                add(content: [["text": "Current explanation", "bold": true], ["image": ["path": png.path]]]), add("defer"), add()
            ])).0 == 0)
            let before = try await fixture.archive.load()
            let entries = before.document.entries
            let bank = try #require(entries.first { $0.expression == "bank" })
            let other = try #require(entries.first { $0.expression == "defer" })
            let header = try result(try await fixture.call(["vocab", "get", bank.id.uuidString]).1)
            let scope = try #require(header["notebookScope"] as? [String: Any])
            let scopeJSON = String(decoding: try JSONSerialization.data(withJSONObject: scope), as: UTF8.self)
            let entryIDs = [other.id, bank.id]
            let reply = try await fixture.call(["vocab", "read", "--entry-ids", entryIDs.map(\.uuidString).joined(separator: ","),
                "--scope", scopeJSON])
            #expect(reply.0 == 0)
            let read = try result(reply.1), values = try #require(read["entries"] as? [[String: Any]])
            #expect(values.compactMap { $0["id"] as? String } == entryIDs.map(\.uuidString))
            #expect(read["revision"] as? UInt64 == before.revision)
            #expect(NSDictionary(dictionary: try #require(read["notebookScope"] as? [String: Any])).isEqual(to: scope))
            #expect(NSDictionary(dictionary: values[1]).isEqual(to: try #require(header["entry"] as? [String: Any])))
            let senseIDs = [bank.senses[1].id, other.senses[0].id, bank.senses[0].id]
            let sensesReply = try await fixture.call(["vocab", "read", "--sense-ids", senseIDs.map(\.uuidString).joined(separator: ",")])
            #expect(sensesReply.0 == 0)
            let senses = try #require(try result(sensesReply.1)["senses"] as? [[String: Any]])
            #expect(senses.compactMap { $0["id"] as? String } == senseIDs.map(\.uuidString))
            let parts = try #require(senses[2]["explanation"] as? [[String: Any]])
            #expect(parts[0]["text"] as? String == "Current explanation" && parts[0]["bold"] == nil)
            #expect(parts[1]["imageID"] != nil && senses[2]["examples"] != nil && senses[2]["semanticLinks"] != nil)
            let missing = try await fixture.call(["vocab", "read", "--sense-ids", senseIDs[0].uuidString + "," + UUID().uuidString])
            #expect(missing.0 == 3 && missing.1["result"] == nil)
            var stale = scope; stale["generation"] = "another-notebook-session"
            let staleJSON = String(decoding: try JSONSerialization.data(withJSONObject: stale), as: UTF8.self)
            #expect(try await fixture.call(["vocab", "read", "--entry-ids", bank.id.uuidString, "--scope", staleJSON]).0 == 4)
            let after = try await fixture.archive.load()
            #expect(after.document == before.document && after.revision == before.revision)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func batchReadSelectorsAndAggregateBudgetRejectInvalidRequests() throws {
        let id = UUID().uuidString
        let invalid = [
            ["vocab", "read"], ["vocab", "read", "--sense-ids", ""], ["vocab", "read", "--entry-ids", "bad"],
            ["vocab", "read", "--entry-ids", id, "--sense-ids", id],
            ["vocab", "read", "--sense-ids", id + ","],
            ["vocab", "read", "--sense-ids", id + "," + id.lowercased()],
            ["vocab", "read", "--entry-ids", (0..<101).map { _ in UUID().uuidString }.joined(separator: ",")]
        ]
        for args in invalid { #expect(throws: CLIError.self) { try CLIArguments(args) } }
        let decoded = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: batch("budget", [
            add(content: [["text": String(repeating: "x", count: 8_000)]])
        ])))
        let plan = try VocabularyCLIPlan(batch: decoded, snapshot: .init(revision: 0, document: .init()),
            fingerprint: "budget", prepared: [:], now: Date())
        let entry = try #require(plan.document.entries.first)
        try VocabularyCLIReadBudget.validate(entry, maximum: 100_000)
        #expect(throws: CLIError.self) { try VocabularyCLIReadBudget.validate([entry, entry], maximum: 100_000) }
        for ids in [[], [entry.id, entry.id], (0..<101).map { _ in UUID() }] {
            #expect(throws: CLIError.self) {
                try VocabularyCLIBatchRead.read(.init(kind: .entries, ids: ids), from: plan.document)
            }
        }
    }

    @Test func canonicalSenseReadAndImageTransportUseOriginalNotebookScope() async throws {
        let fixture = try await Fixture()
        do {
            let png = fixture.directory.appendingPathComponent("image.png")
            try VocabularyImageTestFixture.png().write(to: png)
            #expect(try await fixture.apply(batch("read-image", [add(content: [
                ["text": "A financial institution", "bold": true], ["image": ["path": png.path, "caption": "Bank"]]
            ])])).0 == 0)
            let snapshot = try await fixture.archive.load(), entry = snapshot.document.entries[0], sense = entry.senses[0]
            let response = try await fixture.call(["vocab", "sense", sense.id.uuidString])
            #expect(response.0 == 0)
            let read = try result(response.1), value = try #require(read["sense"] as? [String: Any])
            let parts = try #require(value["explanation"] as? [[String: Any]])
            #expect(parts[0]["text"] as? String == "A financial institution" && parts[0]["bold"] == nil)
            #expect(value["alternateMeanings"] == nil && value["explanations"] == nil)
            let examples = try #require(value["examples"] as? [[String: Any]])
            #expect(examples[0]["source"] is [String: Any] && examples[0]["meaning"] == nil)
            let imageID = try #require(parts[1]["imageID"] as? String)
            let scope = try #require(read["notebookScope"] as? [String: Any])
            let scopeJSON = String(decoding: try JSONSerialization.data(withJSONObject: scope), as: UTF8.self)
            let image = try await fixture.call(["vocab", "image", sense.id.uuidString, imageID, "--scope", scopeJSON])
            #expect(image.0 == 0)
            let encoded = try #require(try result(image.1)["dataBase64"] as? String)
            let bytes = try #require(Data(base64Encoded: encoded))
            let reference = try #require(VocabularyContentPolicy.images(sense.content ?? []).first)
            #expect(bytes == (try await fixture.archive.image(reference)))
            #expect(try await fixture.call(["vocab", "image", sense.id.uuidString, imageID]).0 == 2)
            #expect(try await fixture.call(["vocab", "image", UUID().uuidString, imageID, "--scope", scopeJSON]).0 == 3)
            var wrong = scope; wrong["generation"] = "another-session"
            let wrongJSON = String(decoding: try JSONSerialization.data(withJSONObject: wrong), as: UTF8.self)
            #expect(try await fixture.call(["vocab", "image", sense.id.uuidString, imageID, "--scope", wrongJSON]).0 == 4)
            #expect(try await fixture.call(["vocab", "sense", sense.id.uuidString, "--scope", "{"]).0 == 2)
            #expect(try await fixture.archive.load().document == snapshot.document)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func batchCaptureAndUpdateStoreCoreDefinitionsByLanguage() async throws {
        let fixture = try await Fixture()
        do {
            let japaneseText = "預金を預かる金融機関。"
            let japanese = ["text": japaneseText, "language": "ja"]
            let spanish = ["text": "Entidad que recibe depósitos.", "language": "es"]
            let french = ["text": "Établissement qui reçoit des dépôts.", "language": "fr"]
            let input: [String: Any] = ["version": 1, "idempotencyKey": "localized-definitions",
                "defaults": ["language": "en", "meaningLanguage": "ja"], "entries": [
                    ["expression": "bank", "senses": [["meaning": japaneseText,
                        "addMeaningVariants": [spanish], "tags": ["A1"], "examples": [["text": "The bank is open."]]]]],
                    ["expression": "tree", "senses": [["meaning": "木。", "addMeaningVariants": [
                        ["text": "Planta con un tronco.", "language": "es"]]]]]
                ]]
            let data = try JSONSerialization.data(withJSONObject: input)
            #expect(try await fixture.call(["vocab", "capture", "--stdin", "--dry-run"], stdin: data).0 == 0)
            #expect(try await fixture.archive.load().document.catalog.isEmpty)
            #expect(try await fixture.call(["vocab", "capture", "--stdin"], stdin: data).0 == 0)
            let initial = try await fixture.archive.load()
            #expect(initial.document.catalog.count == 2)
            let entry = try #require(initial.document.catalog.first { $0.expression == "bank" })
            let sense = try #require(entry.senses.first)
            #expect(entry.senses.count == 1)
            #expect(sense.standaloneMeanings == [.init(text: "Entidad que recibe depósitos.", language: .spanish)])

            func update(_ key: String, variants: [[String: String]], revision: UInt64) -> [String: Any] {
                batch(key, [["update": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString,
                    "expectedRevision": revision, "addMeaningVariants": variants]]])
            }
            #expect(try await fixture.apply(update("new-language", variants: [spanish, french], revision: initial.revision)).0 == 0)
            let saved = try await fixture.archive.load()
            let reply = try await fixture.call(["vocab", "sense", sense.id.uuidString])
            #expect(reply.0 == 0)
            let record = try #require(try result(reply.1)["sense"] as? [String: Any])
            #expect(record["meaning"] as? String == japaneseText)
            #expect(record["meaningLanguage"] as? String == "ja")
            #expect(record["meaningVariants"] as? [[String: String]] == [japanese, spanish, french])
            #expect(record["tags"] as? [String] == ["A1"])
            #expect(saved.document.interpretations == initial.document.interpretations)

            let conflict = update("same-language", variants: [
                ["text": "Une autre définition.", "language": "fr"]], revision: saved.revision)
            #expect(try await fixture.apply(conflict).0 == 4)
            #expect(try await fixture.archive.load().document == saved.document)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func senseEditsPreviewThenPreserveImagesAndUpdateOwnedExamplesAndLinks() async throws {
        let fixture = try await Fixture()
        do {
            let png = fixture.directory.appendingPathComponent("image.png")
            try VocabularyImageTestFixture.png().write(to: png)
            #expect(try await fixture.apply(batch("edit-seed", [add(content: [
                ["text": "A financial institution", "bold": true], ["image": ["path": png.path, "caption": "Bank"]]
            ])])).0 == 0)
            var document = try await fixture.archive.load().document
            let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Banking")])
            document.semantics.nodes.append(node)
            let initial = try await fixture.archive.commit(document), entry = initial.document.entries[0], sense = entry.senses[0]
            let blocks = try #require(sense.content), example = sense.examples[0]
            func update(_ key: String, _ fields: [String: Any], revision: UInt64? = nil) -> [String: Any] {
                var fields = fields
                fields["entryID"] = entry.id.uuidString; fields["senseID"] = sense.id.uuidString
                fields["expectedRevision"] = revision ?? initial.revision
                return batch(key, [["update": fields]])
            }
            #expect(try await fixture.apply(update("unsafe-replace", ["explanation": "Flattened"])).0 == 2)
            let edits = update("safe-edits", [
                "contentEdits": [["blockID": blocks[0].id.uuidString, "find": "financial", "replacement": "banking"],
                    ["blockID": blocks[1].id.uuidString, "caption": "Updated caption"]],
                "exampleEdits": [["id": example.id.uuidString, "text": "The bank opens early.", "source": "Article A"]],
                "linkNodes": [["nodeID": node.id.uuidString]]
            ])
            let preview = try await fixture.apply(edits, dry: true)
            #expect(preview.0 == 0)
            let changes = try #require(try result(preview.1)["changes"] as? [String: Any])
            let changed = try #require(changes["senses"] as? [[String: Any]])
            #expect(changed.count == 1 && changed[0]["action"] as? String == "updated")
            #expect(changed[0]["before"] is [String: Any] && changed[0]["after"] is [String: Any])
            #expect(try await fixture.archive.load().document == initial.document)
            #expect(try await fixture.apply(edits).0 == 0)
            let saved = try await fixture.archive.load(), current = saved.document.entries[0].senses[0]
            if case let .text(value) = current.content?[0].content {
                #expect(value.text == "A banking institution" && value.bold)
            } else { Issue.record("Styled text must remain text.") }
            #expect(VocabularyContentPolicy.images(current.content ?? []) == VocabularyContentPolicy.images(blocks))
            #expect(current.examples[0].id == example.id && current.examples[0].text == "The bank opens early.")
            #expect(saved.document.interpretations[0].provenance.source == "Article A")
            #expect(saved.document.semantics.mappings.contains { $0.nodeID == node.id && $0.senseID == sense.id })
            #expect(try await fixture.apply(edits).0 == 0)
            #expect(try await fixture.archive.load().revision == saved.revision)
            let invalid = update("invalid-rollback", ["note": "Must not survive",
                "removeExamples": [UUID().uuidString]], revision: saved.revision)
            #expect(try await fixture.apply(invalid).0 == 3)
            #expect(try await fixture.archive.load().document == saved.document)
            let removal = update("detach", ["removeExamples": [example.id.uuidString],
                "unlinkNodes": [node.id.uuidString]], revision: saved.revision)
            #expect(try await fixture.apply(removal).0 == 0)
            let detached = try await fixture.archive.load().document
            #expect(detached.entries[0].examples.isEmpty && detached.semantics.mappings.isEmpty)
            #expect(detached.semantics.nodes.contains(node))
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func senseRemovalPreservesOtherSensesSharedNodesAndSourceEvidence() async throws {
        let fixture = try await Fixture()
        do {
            let seeded = try await fixture.archive.addEntries([
                .init(expression: "bank", meaning: "Financial institution", example: "The bank opened."),
                .init(expression: "bank", meaning: "River edge", example: "We reached the bank.")
            ]).0
            var document = seeded.document
            let entry = document.entries[0], node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Shared node")])
            document.semantics.nodes = [node]
            document.semantics.mappings = entry.senses.map { .init(nodeID: node.id, senseID: $0.id) }
            let before = try await fixture.archive.commit(document)
            let input: [String: Any] = ["version": 2, "idempotencyKey": "remove-sense", "expectedRevision": before.revision,
                "operations": [["remove": ["entryID": entry.id.uuidString, "senseID": entry.senses[0].id.uuidString]]]]
            #expect(try await fixture.apply(input, dry: true).0 == 0)
            #expect(try await fixture.archive.load().document == before.document)
            #expect(try await fixture.apply(input).0 == 0)
            let after = try await fixture.archive.load()
            #expect(after.document.entries[0].senses.map(\.id) == [entry.senses[1].id])
            #expect(after.document.entries[0].examples.map(\.id) == entry.senses[1].examples.map(\.id))
            #expect(after.document.semantics.nodes == [node] && after.document.semantics.mappings.count == 1)
            #expect(after.document.sources == before.document.sources)
            #expect(try await fixture.apply(input).0 == 0)
            var stale = input; stale["idempotencyKey"] = "stale-removal"
            #expect(try await fixture.apply(stale).0 == 4)
            #expect(try await fixture.archive.load().document == after.document)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func explicitMergeUsesDestinationContentAndSupportsDryRunReplayAndConflict() async throws {
        let fixture = try await Fixture()
        do {
            let initial = try await fixture.archive.addEntries([
                .init(expression: "bank", meaning: "financial institution", note: "Keep target", example: "The bank opened."),
                .init(expression: "bank", meaning: "provider of banking services", note: "Drop source", example: "I visited the bank.")
            ]).0
            let entry = initial.document.entries[0]
            var linked = initial.document
            let node = VocabularyMeaningNode(id: UUID(), labels: [.init(text: "Financial services")])
            linked.semantics.nodes = [node]
            linked.semantics.mappings = [.init(nodeID: node.id, senseID: entry.senses[1].id)]
            let linkedSnapshot = try await fixture.archive.commit(linked)
            let merge: [String: Any] = ["merge": ["entryID": entry.id.uuidString,
                "sourceSenseID": entry.senses[1].id.uuidString, "targetSenseID": entry.senses[0].id.uuidString]]
            let input: [String: Any] = ["version": 2, "idempotencyKey": "explicit-merge", "expectedRevision": linkedSnapshot.revision,
                "operations": [merge]]
            #expect(try await fixture.apply(input, dry: true).0 == 0)
            #expect(try await fixture.archive.load().document == linkedSnapshot.document)
            #expect(try await fixture.apply(input).0 == 0)
            let saved = try await fixture.archive.load()
            #expect(saved.document.entries[0].senses.count == 1)
            #expect(saved.document.entries[0].senses[0].note == "Keep target")
            #expect(Set(saved.document.entries[0].examples.map(\.id)) == Set(entry.examples.map(\.id)))
            #expect(try await fixture.apply(input).0 == 0)
            #expect(try await fixture.archive.load().revision == saved.revision)
            var stale = input; stale["idempotencyKey"] = "stale-merge"
            #expect(try await fixture.apply(stale).0 != 0)
            var missing = input; missing.removeValue(forKey: "expectedRevision")
            #expect(throws: CLIError.self) { try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: missing)) }
            #expect(try await fixture.archive.load().document == saved.document)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func legacyAndStaleRequestsNeverReachTheArchive() async throws {
        let fixture = try await Fixture()
        do {
            let greeting = try await fixture.send(CLIRequest(command: .hello))
            let identity = try #require(greeting.server)
            for legacy in [true, false] {
                var request = CLIRequest(command: .apply)
                request.version = legacy ? CLIServiceIdentity.protocolVersion - 1 : CLIServiceIdentity.protocolVersion
                request.targetAppPath = identity.appPath
                request.serverInstanceID = legacy ? identity.instanceID : UUID()
                request.batch = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: batch("rejected", [add()])))
                let reply = try await fixture.send(request)
                #expect(reply.ok == false && reply.error?.code == .unavailable)
                #expect(reply.version == request.version)
            }
            #expect(try await fixture.archive.load().document.catalog.isEmpty)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test(arguments: ["path", "capabilities"])
    func mismatchedServerRejectsBeforeSendingMaterial(_ mismatch: String) async throws {
        let fixture = try await Fixture(mismatch: mismatch)
        do {
            let bytes = try JSONSerialization.data(withJSONObject: batch("must-not-write", [add()]))
            let reply = try await fixture.call(["vocab", "apply", "--stdin"], stdin: bytes)
            #expect(reply.0 == 6)
            #expect(try await fixture.archive.load().document.catalog.isEmpty)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func resourceEditTransportsReadScopeAndRejectsItsOmission() async throws {
        let fixture = try await Fixture()
        do {
            let status = try await fixture.call(["status"])
            let server = try #require(status.1["server"] as? [String: Any])
            #expect(server["appPath"] as? String == fixture.app.resolvingSymlinksInPath().path)
            let read = try result(status.1)
            let input: [String: Any] = ["version": 2, "idempotencyKey": "scope-through-wire",
                "expectedRevision": try #require(read["revision"]),
                "operations": [["put": ["resource": "nodes", "value": ["id": UUID().uuidString,
                    "labels": [["id": UUID().uuidString, "text": "Synthetic node"]]]]]]]
            let missing = try await fixture.call(["vocab", "apply", "--stdin"], stdin: JSONSerialization.data(withJSONObject: input))
            #expect(missing.0 == 4)
            #expect(try await fixture.archive.load().document.semantics.nodes.isEmpty)
            var scoped = input
            scoped["notebookScope"] = try #require(read["notebookScope"])
            let bytes = try JSONSerialization.data(withJSONObject: scoped)
            let preview = try await fixture.call(["vocab", "apply", "--stdin", "--dry-run"], stdin: bytes)
            #expect(preview.0 == 0)
            #expect(try await fixture.archive.load().document.semantics.nodes.isEmpty)
            #expect(try await fixture.call(["vocab", "apply", "--stdin"], stdin: bytes).0 == 0)
            #expect(try await fixture.archive.load().document.semantics.nodes.count == 1)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func categoryGuidanceTravelsThroughTheInstalledCLIContract() async throws {
        let fixture = try await Fixture()
        do {
            var document = VocabularyDocument()
            try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: [])
            _ = try await fixture.archive.commit(document)
            let base = try #require(document.classification.categories.first { $0.key == "content.general.polarity.negate" })
            let read = try result(try await fixture.call(["data", "get", "categories", base.id.uuidString]).1)
            let record = try #require(read["record"] as? [String: Any])
            #expect((record["examples"] as? [[String: Any]])?.isEmpty == false)
            #expect((record["references"] as? [[String: Any]])?.first?["identifier"] as? String == "9.4.6.1")
            let compact = try result(try await fixture.call(["data", "list", "categories", "--query", try #require(base.key), "--summary"]).1)
            let rows = try #require(compact["records"] as? [[String: Any]])
            #expect(rows.count == 1 && rows[0]["id"] as? String == base.id.uuidString)
            #expect(rows[0]["definition"] != nil && rows[0]["localizations"] == nil && rows[0]["references"] == nil)
            let custom = UUID()
            let value: [String: Any] = ["id": custom.uuidString, "axis": "content",
                "labels": [["id": UUID().uuidString, "text": "Local domain"]], "definition": "Definition",
                "examples": [["text": "değil", "language": "tr"]], "scopeNote": "Do not confuse with refusal.",
                "localizations": [["language": "tr", "name": "Olumsuzlama", "definition": "Bir önermeyi reddeder."]],
                "references": [["source": "SIL Semantic Domains v4", "identifier": "9.4.6.1",
                    "url": "https://semdom.org/v4/9.4.6.1/", "relationship": "adapted", "license": "CC-BY-SA-4.0"]]]
            let batch: [String: Any] = ["version": 2, "idempotencyKey": "category-guidance", "expectedRevision": 1,
                "operations": [["put": ["resource": "categories", "value": value]]]]
            #expect(try await fixture.apply(batch, dry: true).0 == 0)
            #expect(try await fixture.archive.load().revision == 1)
            #expect(try await fixture.apply(batch).0 == 0)
            let snapshot = try await fixture.archive.load()
            let saved = try #require(snapshot.document.classification.categories.first { $0.id == custom })
            #expect(saved.examples == [.init(text: "değil", language: "tr")])
            #expect(saved.scopeNote == "Do not confuse with refusal.")
            #expect(saved.localizations.first?.language == "tr")
            #expect(VocabularyCategoryLocalizationPolicy.presentation(saved, identifiers: ["tr"]).name == "Olumsuzlama")
            #expect(saved.references.first?.license == "CC-BY-SA-4.0")
            #expect(snapshot.document.catalog.isEmpty)
            let reply = try result(try await fixture.call(["data", "get", "categories", custom.uuidString]).1)
            #expect((reply["record"] as? [String: Any])?["scopeNote"] as? String == saved.scopeNote)
            let overlay: [String: Any] = ["categoryID": base.id.uuidString,
                "examples": [["text": "a local illustration", "language": "en"]], "scopeNote": "Local scope", "references": [],
                "localizations": [["language": "fr", "name": "Nom local", "definition": "Définition locale."]]]
            let overridden: [String: Any] = ["version": 2, "idempotencyKey": "guidance-overlay", "expectedRevision": 2,
                "operations": [["put": ["resource": "categoryOverrides", "value": overlay]]]]
            #expect(try await fixture.apply(overridden).0 == 0)
            let local = VocabularyClassificationPolicy.effective(base, in: fixture.store.classification)
            #expect(local.scopeNote == "Local scope" && local.references.isEmpty)
            #expect(VocabularyCategoryLocalizationPolicy.presentation(local, identifiers: ["fr"]).name == "Nom local")
            let reset: [String: Any] = ["version": 2, "idempotencyKey": "guidance-inherit", "expectedRevision": 3,
                "operations": [["put": ["resource": "categoryOverrides", "value": ["categoryID": base.id.uuidString,
                    "examples": NSNull(), "scopeNote": NSNull(), "references": NSNull(), "localizations": NSNull()]]]]]
            #expect(try await fixture.apply(reset).0 == 0)
            #expect(VocabularyClassificationPolicy.effective(base, in: fixture.store.classification) == base)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func categoriesSupportCaptureOverridesMultiParentsAndProtectedBuiltIns() async throws {
        let fixture = try await Fixture()
        do {
            var document = VocabularyDocument()
            try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: [])
            _ = try await fixture.archive.commit(document)
            let listed = try await fixture.call(["data", "list", "categories", "--query", "content.degree.near-zero"])
            #expect(listed.0 == 0)
            #expect(try result(listed.1)["total"] as? Int == 1)
            let capture: [String: Any] = ["version": 1, "idempotencyKey": "categorized-capture",
                "defaults": ["language": "en", "meaningLanguage": "zh-Hans"],
                "meanings": [["ref": "almost-none", "title": "几乎没有", "categories": ["content.degree.near-zero", "content.quantity.none"]]],
                "entries": [["expression": "barely", "senses": [["meaning": "几乎不", "associations": [["meaning": "almost-none"]]]]]]]
            let bytes = try JSONSerialization.data(withJSONObject: capture)
            #expect(try await fixture.call(["vocab", "capture", "--stdin", "--dry-run"], stdin: bytes).0 == 0)
            #expect(try await fixture.archive.load().revision == 1)
            let savedReply = try await fixture.call(["vocab", "capture", "--stdin"], stdin: bytes)
            #expect(savedReply.0 == 0)
            let outcomes = try #require(try result(savedReply.1)["operations"] as? [[String: Any]])
            let captureResult = try #require(outcomes.first)
            let meanings = try #require(captureResult["meanings"] as? [[String: Any]])
            let categories = try #require(meanings.first?["categories"] as? [[String: Any]])
            #expect(categories.count == 2 && categories.allSatisfy { $0["created"] as? Bool == true })
            #expect((captureResult["summary"] as? [String: Any])?["categoryMembershipCount"] as? Int == 2)
            let snapshot = try await fixture.archive.load()
            #expect(snapshot.document.classification.memberships.count == 2)
            #expect(snapshot.document.classification.memberships.allSatisfy { $0.provenance.origin == .model && $0.provenance.status == .confirmed })
            #expect(try result(try await fixture.call(["vocab", "capture", "--stdin"], stdin: bytes).1)["replayed"] as? Bool == true)
            let builtIn = try #require(snapshot.document.classification.categories.first { $0.key == "content.degree.near-zero" })
            let other = try #require(snapshot.document.classification.categories.first { $0.key == "content.quantity.none" })
            let custom = UUID(), nodeID = snapshot.document.semantics.nodes[0].id
            func put(_ resource: String, _ value: [String: Any]) -> [String: Any] { ["put": ["resource": resource, "value": value]] }
            func changes(_ key: String, _ revision: Int, _ operations: [[String: Any]]) -> [String: Any] {
                ["version": 2, "idempotencyKey": key, "expectedRevision": revision, "operations": operations]
            }
            let operations = [
                put("categories", ["id": custom.uuidString, "axis": "content", "labels": [["id": UUID().uuidString, "text": "My category"]]]),
                put("categoryParents", ["id": UUID().uuidString, "categoryID": custom.uuidString, "parentID": builtIn.id.uuidString]),
                put("categoryParents", ["id": UUID().uuidString, "categoryID": custom.uuidString, "parentID": other.id.uuidString]),
                put("categoryMemberships", ["id": UUID().uuidString, "nodeID": nodeID.uuidString, "categoryID": custom.uuidString]),
                put("categoryOverrides", ["categoryID": builtIn.id.uuidString, "isHidden": true])
            ]
            #expect(try await fixture.apply(changes("custom-category", 2, operations)).0 == 0)
            #expect(fixture.store.classification.categories.contains { $0.id == custom })
            #expect(fixture.store.classification.parents.filter { $0.categoryID == custom }.count == 2)
            #expect(try await fixture.apply(changes("protected-category", 3, [put("categories",
                ["id": builtIn.id.uuidString, "definition": "Must not overwrite catalog"])] )).0 == 2)
            let remove: [[String: Any]] = [["delete": ["resource": "categories", "id": custom.uuidString]]]
            #expect(try await fixture.apply(changes("remove-category", 3, remove)).0 == 0)
            let final = try await fixture.archive.load()
            #expect(final.document.classification.memberships.count == 2)
            #expect(final.document.semantics == snapshot.document.semantics && final.document.entries == snapshot.document.entries)
            #expect(try await fixture.apply(changes("stale-category", 3, operations)).0 == 4)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    /// A practice capture is complete when the saved example and both links can be read
    /// through the CLI. A second expression should reuse the node in the same notebook.
    @Test func practiceCaptureReadsBackClassificationAndReusesMeaning() async throws {
        let fixture = try await Fixture()
        do {
            var document = VocabularyDocument()
            try VocabularyClassificationCatalog.bundled().install(in: &document.classification, nodes: [])
            _ = try await fixture.archive.commit(document)

            func read(_ arguments: [String]) async throws -> [String: Any] {
                let reply = try await fixture.call(arguments)
                try #require(reply.0 == 0, "\(reply.1["error"] ?? "")")
                return try result(reply.1)
            }

            func records(_ resource: String, related id: String) async throws -> [[String: Any]] {
                let reply = try await read(["data", "list", resource, "--related", id])
                return try #require(reply["records"] as? [[String: Any]])
            }

            func task(expression: String, example: String, translation: String, meaning: [String: Any]) -> [String: Any] {
                ["version": 1, "idempotencyKey": UUID().uuidString,
                 "defaults": ["language": "en", "meaningLanguage": "zh-Hans", "sourceKind": "captured"],
                 "meanings": [meaning],
                 "entries": [["expression": expression, "kind": "expression",
                              "senses": [["meaning": "影响结果",
                                          "examples": [["text": example, "translation": translation]],
                                          "associations": [["meaning": "have-an-influence"]]]]]]]
            }

            func capture(_ task: [String: Any]) async throws -> [String: Any] {
                let input = try JSONSerialization.data(withJSONObject: task)
                let reply = try await fixture.call(["vocab", "capture", "--stdin"], stdin: input)
                try #require(reply.0 == 0, "\(reply.1["error"] ?? "")")
                return try result(reply.1)
            }

            func verifyEntry(in receipt: [String: Any], example: String) async throws -> (senseID: String, nodeID: String) {
                #expect(receipt["dryRun"] as? Bool == false)
                let outcomes = try #require(receipt["operations"] as? [[String: Any]])
                let outcome = try #require(outcomes.first)
                let entries = try #require(outcome["entries"] as? [[String: Any]])
                let meanings = try #require(outcome["meanings"] as? [[String: Any]])
                let entryID = try #require(entries.first?["entryID"] as? String)
                let nodeID = try #require(meanings.first?["nodeID"] as? String)
                let reply = try await read(["vocab", "get", entryID])
                let entry = try #require(reply["entry"] as? [String: Any])
                let senses = try #require(entry["senses"] as? [[String: Any]])
                try #require(senses.count == 1)
                let senseID = try #require(senses[0]["id"] as? String)
                #expect(senses[0]["meaning"] as? String == "影响结果")
                let examples = try #require(senses[0]["examples"] as? [[String: Any]])
                #expect(examples.compactMap { $0["text"] as? String } == [example])
                let mappings = try await records("mappings", related: senseID)
                #expect(mappings.compactMap { $0["nodeID"] as? String } == [nodeID])
                return (senseID, nodeID)
            }

            let definition = "对事物的状态、发展或结果产生作用，但未必完全决定它。"
            let firstExample = "These three factors influence the result."
            let first = try await capture(task(expression: "influence the result", example: firstExample,
                translation: "这三个因素影响结果。",
                meaning: ["ref": "have-an-influence", "title": "对某事产生影响",
                          "definition": definition,
                          "kind": "concept", "categories": ["content.general"]]))
            let firstIDs = try await verifyEntry(in: first, example: firstExample)
            let category = try #require(document.classification.categories.first { $0.key == "content.general" })
            let memberships = try await records("categoryMemberships", related: category.id.uuidString)
            #expect(memberships.compactMap { $0["nodeID"] as? String } == [firstIDs.nodeID])

            let baseline = try await read(["data", "get", "nodes", firstIDs.nodeID])
            #expect((baseline["record"] as? [String: Any])?["definition"] as? String == definition)
            let secondExample = "Even small changes can affect the outcome."
            var reuse = task(expression: "affect the outcome", example: secondExample,
                translation: "即使是小变化也可能影响结果。",
                meaning: ["ref": "have-an-influence", "id": firstIDs.nodeID])
            reuse["defaults"] = ["language": "en", "meaningLanguage": "zh-Hans", "sourceKind": "generated"]
            reuse["notebookScope"] = try #require(baseline["notebookScope"])
            reuse["expectedRevision"] = try #require(baseline["revision"])
            let second = try await capture(reuse)
            let secondIDs = try await verifyEntry(in: second, example: secondExample)
            #expect(secondIDs.nodeID == firstIDs.nodeID)
            #expect(try await capture(reuse)["replayed"] as? Bool == true)
            let batchRead = try await read(["vocab", "read", "--sense-ids", firstIDs.senseID + "," + secondIDs.senseID])
            let savedSenses = try #require(batchRead["senses"] as? [[String: Any]])
            #expect(savedSenses.compactMap { $0["id"] as? String } == [firstIDs.senseID, secondIDs.senseID])
            let reverse = try await records("mappings", related: firstIDs.nodeID)
            #expect(reverse.count == 2)
            #expect(Set(reverse.compactMap { $0["senseID"] as? String }) == [firstIDs.senseID, secondIDs.senseID])
            let snapshot = try await fixture.archive.load()
            #expect(snapshot.document.semantics.nodes.count == 1)
            #expect(snapshot.document.classification.memberships.count == 1)
            #expect(snapshot.document.entries.flatMap(\.senses).allSatisfy { $0.review == nil && ($0.reviewCards ?? []).isEmpty })
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func captureTaskBuildsActiveMeaningGraphWithStableIDsAndReplay() async throws {
        let fixture = try await Fixture()
        do {
            let input: [String: Any] = ["version": 1, "idempotencyKey": "capture-bank",
                "defaults": ["language": "en", "meaningLanguage": "zh-Hans"],
                "meanings": [
                    ["ref": "finance", "title": "金融机构", "aliases": [["text": "banking", "language": "en"]], "cues": ["存钱的地方"]],
                    ["ref": "water", "title": "水岸边缘"],
                    ["ref": "request", "title": "礼貌请求", "kind": "function"]
                ],
                "entries": [
                    ["expression": "bank", "senses": [
                        ["meaning": "银行", "note": "Keep this personal note", "tags": ["finance"],
                            "examples": [["text": "🏦 The bank is open.", "translation": "银行开门了。"]],
                            "explanation": "the bank", "associations": [["meaning": "finance"]]],
                        ["meaning": "河岸", "examples": [["text": "We sat on the bank.", "translation": "我们坐在河岸上。"]],
                            "associations": [["meaning": "water"]]]
                    ]],
                    ["expression": "Could you", "kind": "pattern", "senses": [
                        ["meaning": "委婉请求", "examples": [["text": "Could you help me?", "translation": "你能帮我吗？"]],
                            "explanation": "Could you + verb? (neutral)", "associations": [["meaning": "request"]]]
                    ]]
                ], "relations": [["from": "finance", "to": "water", "kind": "related", "note": "同形词，不是同义关系"]]]
            func capture(_ value: [String: Any], dry: Bool = false) async throws -> (Int32, [String: Any]) {
                var scoped = value
                if scoped["expectedRevision"] != nil, let scope = try await fixture.archive.load().scope {
                    scoped["notebookScope"] = ["workspaceID": scope.workspaceId, "notebookID": scope.notebookId.uuidString,
                        "generation": scope.generation]
                }
                return try await fixture.call(["vocab", "capture", "--stdin"] + (dry ? ["--dry-run"] : []),
                    stdin: JSONSerialization.data(withJSONObject: scoped))
            }
            let preview = try await capture(input, dry: true)
            #expect(preview.0 == 0)
            #expect(try await fixture.archive.load().document.catalog.isEmpty)
            let committed = try await capture(input)
            #expect(committed.0 == 0)
            let planned = try result(preview.1)["operations"] as? [[String: Any]]
            let saved = try result(committed.1)["operations"] as? [[String: Any]]
            #expect(try JSONSerialization.data(withJSONObject: #require(planned), options: .sortedKeys) ==
                JSONSerialization.data(withJSONObject: #require(saved), options: .sortedKeys))
            let snapshot = try await fixture.archive.load()
            let document = snapshot.document
            #expect(document.entries.count == 2 && document.entries.flatMap(\.senses).count == 3)
            #expect(document.sources.count == 3 && document.occurrences.count == 3 && document.interpretations.count == 3)
            #expect(document.sources.allSatisfy { $0.kind == .generated })
            #expect(document.semantics.mappings.allSatisfy { $0.provenance.origin == .model && $0.provenance.status == .confirmed })
            #expect(document.semantics.patterns.allSatisfy { $0.provenance.status == .confirmed })
            #expect(document.semantics.mappings.last?.relation == .realizesFunction)
            #expect(document.occurrences.first?.ranges.first?.location == 7) // Emoji uses two UTF-16 code units.
            let matches = VocabularyMeaningBrowserProjection.items(index: document.semantics,
                entries: document.entries, query: "存钱的地方")
            #expect(matches.count == 1 && matches[0].selections.count == 1)
            #expect(try result(try await capture(input).1)["replayed"] as? Bool == true)
            var changed = input; changed["relations"] = []
            #expect(try await capture(changed).0 == 4)
            var invalid = input; invalid["idempotencyKey"] = "invalid-reference"
            invalid["entries"] = [["expression": "fresh", "senses": [["meaning": "新的"]]]]
            invalid["relations"] = [["from": "finance", "to": "missing", "kind": "related"]]
            #expect(try await capture(invalid).0 == 2)
            #expect(try await fixture.archive.load().revision == snapshot.revision)
            #expect(try await fixture.archive.load().document == snapshot.document)
            let first = try #require(document.entries.first { $0.expression == "bank" })
            let sense = try #require(first.senses.first { $0.meaning == "银行" })
            let node = try #require(document.semantics.nodes.first { $0.title == "金融机构" })
            let append: [String: Any] = ["version": 1, "idempotencyKey": "capture-existing", "expectedRevision": snapshot.revision,
                "defaults": ["language": "en", "meaningLanguage": "zh-Hans"],
                "meanings": [["ref": "finance", "id": node.id.uuidString]],
                "entries": [["expression": "bank", "senses": [["id": sense.id.uuidString, "tags": ["new"],
                    "examples": [["text": "The bank closes at five.", "translation": "银行五点关门。"]],
                    "associations": [["meaning": "finance"]]]]]]]
            #expect(try await capture(append).0 == 0)
            let updated = try await fixture.archive.load().document
            #expect(updated.catalog.count == 2 && updated.catalog.flatMap(\.senses).count == 3)
            #expect(updated.semantics.nodes.count == 3)
            #expect(updated.entries.first { $0.id == first.id }?.senses.first { $0.id == sense.id }?.note == sense.note)
            var stale = append; stale["idempotencyKey"] = "capture-stale"
            #expect(try await capture(stale).0 == 4)
            let schema = try await Self.run(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lingrove"),
                arguments: ["schema", "capture"], stdin: nil)
            #expect(schema.0 == 0)
            #expect(try #require(JSONSerialization.jsonObject(with: schema.1) as? [String: Any])["title"] as? String ==
                "Lingrove capture task v1")
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func externalAgentWritesDirectlyToTheCorpus() async throws {
        let fixture = try await Fixture()
        do {
            let entry = UUID().uuidString, sense = UUID().uuidString, source = UUID().uuidString
            let occurrence = UUID().uuidString, accepted = UUID().uuidString, candidate = UUID().uuidString
            let node = UUID().uuidString, pattern = UUID().uuidString, mapping = UUID().uuidString
            let cue = UUID().uuidString, target = UUID().uuidString
            func put(_ resource: String, _ value: [String: Any]) -> [String: Any] {
                ["put": ["resource": resource, "value": value]]
            }
            func resourceBatch(_ key: String, _ revision: Int, _ operations: [[String: Any]]) -> [String: Any] {
                ["version": 2, "idempotencyKey": key, "expectedRevision": revision, "operations": operations]
            }
            let input = resourceBatch("organize", 0, [
                put("sources", ["id": source, "text": "We pushed the meeting back.", "kind": "captured"]),
                put("occurrences", ["id": occurrence, "sourceID": source, "ranges": [["location": 3, "length": 6]]]),
                put("entries", ["id": entry, "expression": "push back", "language": "en", "kind": "expression"]),
                put("senses", ["id": sense, "entryID": entry, "meaning": "推迟", "meaningLanguage": "zh-Hans"]),
                put("interpretations", ["id": accepted, "occurrenceID": occurrence, "senseID": sense,
                    "status": "accepted", "translation": "我们推迟了会议。"]),
                put("interpretations", ["id": candidate, "occurrenceID": occurrence, "status": "candidate"]),
                put("nodes", ["id": node, "labels": [["id": UUID().uuidString, "text": "推迟安排", "language": "zh-Hans"]]]),
                put("patterns", ["id": pattern, "senseID": sense, "template": "push [event] back"]),
                put("mappings", ["id": mapping, "nodeID": node, "senseID": sense, "patternID": pattern, "evidenceIDs": [accepted]]),
                put("cues", ["id": cue, "text": "往后挪"]),
                put("cueTargets", ["id": target, "cueID": cue, "nodeID": node])
            ])
            #expect(try await fixture.apply(input, dry: true).0 == 0)
            #expect(try await fixture.archive.load().document.sources.isEmpty)
            let committed = try await fixture.apply(input)
            #expect(committed.0 == 0)
            #expect(fixture.store.entries.first?.examples.first?.id.uuidString == accepted)
            let catalog = try await fixture.call(["data", "get", "senses", sense])
            #expect(catalog.0 == 0)
            let unresolved = try await fixture.call(["data", "list", "interpretations", "--related", occurrence, "--status", "candidate"])
            #expect(unresolved.0 == 0)
            #expect(try result(unresolved.1)["total"] as? Int == 1)
            #expect(try await fixture.call(["vocab", "list"]).1["ok"] as? Bool == true)
            let annotate = resourceBatch("annotate", 1, [put("senses", ["id": sense,
                "note": "Personal note", "tags": ["scheduling"]])])
            #expect(try await fixture.apply(annotate).0 == 0)
            #expect(fixture.store.entries.first?.examples.first?.id.uuidString == accepted)
            #expect(fixture.store.entries.first?.senses.first?.note == "Personal note")
            let replayed = try await fixture.apply(input)
            #expect(replayed.0 == 0)
            #expect(try result(replayed.1)["replayed"] as? Bool == true)
            let stale = resourceBatch("stale", 0, [put("nodes", ["id": node, "definition": "Stale edit"])])
            #expect(try await fixture.apply(stale).0 == 4)
            let invalid = resourceBatch("dangling-delete", 2, [["delete": ["resource": "sources", "id": source]]])
            #expect(try await fixture.apply(invalid).0 == 2)
            let unknown = resourceBatch("unknown", 2, [put("nodes", ["id": node,
                "labels": [["id": UUID().uuidString, "text": "Oops", "prefered": true]]])])
            #expect(try await fixture.apply(unknown).0 == 2)
            let immutable = resourceBatch("source-edit", 2, [put("sources", ["id": source, "text": "Edited evidence"] )])
            #expect(try await fixture.apply(immutable).0 == 4)
            let retained = try await fixture.archive.load()
            #expect(retained.document.sources.count == 1 && retained.document.interpretations.count == 2)
            #expect(retained.document.semantics.mappings[0].evidenceIDs.map(\.uuidString) == [accepted])
            #expect(retained.document.semantics.nodes[0].provenance == .init(origin: .model, status: .confirmed))
            #expect(retained.document.semantics.mappings[0].provenance.status == .confirmed)
            #expect(retained.document.semantics.cueTargets[0].provenance.status == .confirmed)
            #expect(try await fixture.call(["data", "get", "sources", source]).0 == 0)
            let traditional = batch("edit-saved-sense", [["update": ["entryID": entry, "senseID": sense,
                "expectedRevision": 2, "note": "Edited through the CLI"]]])
            #expect(try await fixture.apply(traditional).0 == 0)
            #expect(fixture.store.entries.first?.senses.first?.note == "Edited through the CLI")
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func deletingExplicitDependenciesTogetherAndPublishingTheSchemaWorkThroughTheExecutable() async throws {
        let fixture = try await Fixture()
        do {
            let source = UUID().uuidString, occurrence = UUID().uuidString
            let seed: [String: Any] = ["version": 2, "expectedRevision": 0, "idempotencyKey": "raw-source", "operations": [
                ["put": ["resource": "sources", "value": ["id": source, "text": "raw material", "kind": "imported"]]],
                ["put": ["resource": "occurrences", "value": ["id": occurrence, "sourceID": source, "ranges": []]]]
            ]]
            #expect(try await fixture.apply(seed).0 == 0)
            let get = try await fixture.call(["data", "get", "sources", source])
            let record = try #require(try result(get.1)["record"] as? [String: Any])
            let replay: [String: Any] = ["version": 2, "expectedRevision": 1, "idempotencyKey": "unchanged-source", "operations": [
                ["put": ["resource": "sources", "value": record]]]]
            #expect(try await fixture.apply(replay).0 == 0)
            let remove: [String: Any] = ["version": 2, "expectedRevision": 2, "idempotencyKey": "delete-raw", "operations": [
                ["delete": ["resource": "occurrences", "id": occurrence]], ["delete": ["resource": "sources", "id": source]]]]
            #expect(try await fixture.apply(remove).0 == 0)
            #expect(try await fixture.archive.load().document.sources.isEmpty)
            let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lingrove")
            let schema = try await Self.run(tool, arguments: ["schema"], stdin: nil)
            let object = try #require(JSONSerialization.jsonObject(with: schema.1) as? [String: Any])
            #expect(schema.0 == 0 && object["allOf"] != nil)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func unknownContextPlansAndWritesTheRequiredEnvelopeVersion() async throws {
        let fixture = try await Fixture()
        do {
            let input = batch("unknown-context", [["add": ["expression": "report", "language": "en", "kind": "word",
                "meaning": "报告", "examples": [["text": "The report is ready.", "completeness": "unknown",
                    "ranges": [["location": 4, "length": 6]]]]]]])
            #expect(try await fixture.apply(input, dry: true).0 == 0)
            #expect(try await fixture.archive.load().document.entries.isEmpty)
            #expect(try await fixture.apply(input).0 == 0)
            let saved = try await fixture.archive.load()
            #expect(saved.document.schemaVersion == VocabularyDocument.currentVersion &&
                saved.document.entries[0].examples[0].completeness == .unknown)
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @MainActor private struct Fixture {
        let directory: URL
        let app: URL
        let root: URL
        let archive: VocabularyArchive
        let store: VocabularyStore
        let server: CLIMailboxServer
        init(oversizedReply: Bool = false, mismatch: String? = nil) async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("lingrove-cli-" + UUID().uuidString)
            app = directory.appendingPathComponent("Fixture.app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let name = "Lingrove CLI Test " + UUID().uuidString
            let info = ["CFBundleName": name, "CFBundleIdentifier": "test.lingrove.cli", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            root = CLIFileIO.directory(appName: name)
            archive = VocabularyArchive(url: directory.appendingPathComponent("notebook.sqlite"))
            store = VocabularyStore(archive: archive); await store.load()
            let store = store
            var identity = CLIServiceIdentity(appURL: app)
            if mismatch == "path" { identity.appPath += ".other" }
            if mismatch == "capabilities" { identity.capabilities = [] }
            server = CLIMailboxServer(root: root, identity: identity) { request in
                if oversizedReply { return .init(requestID: request.id, ok: true, result: .string(String(repeating: "x", count: CLIInputPolicy.maximumBytes))) }
                return await store.executeCLI(request)
            }
            try await server.start()
        }
        func close() async {
            await server.stop()
            await store.shutdown()
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        func send(_ request: CLIRequest) async throws -> CLIReply {
            let name = request.id.uuidString + ".json"
            let pending = root.appendingPathComponent("requests/" + name)
            let response = root.appendingPathComponent("replies/" + name)
            defer { try? FileManager.default.removeItem(at: pending); try? FileManager.default.removeItem(at: response) }
            try CLIFileIO.publish(JSONEncoder().encode(request), to: pending)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: response.path) {
                    return try JSONDecoder().decode(CLIReply.self, from: CLIFileIO.read(response))
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CLIError(code: .timeout, message: "Synthetic mailbox did not reply.")
        }
        func call(_ arguments: [String], stdin: Data? = nil) async throws -> (Int32, [String: Any]) {
            let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lingrove")
            #expect(FileManager.default.isExecutableFile(atPath: tool.path))
            let result = try await VocabularyCLITests.run(tool, arguments: ["--app", app.path, "--no-launch", "--timeout", "5"] + arguments, stdin: stdin)
            let object = try #require(JSONSerialization.jsonObject(with: result.1) as? [String: Any])
            return (result.0, object)
        }
        func apply(_ object: [String: Any], dry: Bool = false) async throws -> (Int32, [String: Any]) {
            var scoped = object
            if scoped["notebookScope"] == nil, let saved = try await archive.load().scope {
                scoped["notebookScope"] = ["workspaceID": saved.workspaceId, "notebookID": saved.notebookId.uuidString,
                    "generation": saved.generation]
            }
            let data = try JSONSerialization.data(withJSONObject: scoped)
            return try await call(["vocab", "apply", "--stdin"] + (dry ? ["--dry-run"] : []), stdin: data)
        }
    }

    /// Process waiting/pipe draining is blocking OS work, explicitly run away from MainActor so
    /// the app-hosted server can handle the child request and update its observed store.
    @concurrent private static func run(_ tool: URL, arguments: [String], stdin: Data?) async throws -> (Int32, Data) {
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = tool; process.arguments = arguments; process.standardOutput = output
        process.standardError = FileHandle.nullDevice; process.standardInput = input
        try process.run()
        if let stdin { try input.fileHandleForWriting.write(contentsOf: stdin) }
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private func batch(_ key: String, _ operations: [[String: Any]]) -> [String: Any] {
        ["version": 1, "idempotencyKey": key, "operations": operations]
    }
    private func add(_ expression: String = "bank", content: [[String: Any]] = []) -> [String: Any] {
        ["add": ["expression": expression, "language": "en", "kind": "word", "meaning": "银行", "meaningLanguage": "zh-Hans",
            "note": "Agent material", "content": content, "examples": [["text": "The bank is open.", "translation": "银行开门了。", "translationLanguage": "zh-Hans"]]]]
    }
    private func result(_ reply: [String: Any]) throws -> [String: Any] { try #require(reply["result"] as? [String: Any]) }

    @Test func listCanFilterTheUnknownLanguageCodeItExports() async throws {
        let fixture = try await Fixture()
        do {
            _ = try await fixture.archive.save(.init(expression: "compatible", dictionaryForm: "compatible", language: nil, kind: .word))
            let (status, reply) = try await fixture.call(["vocab", "list", "--language", "und"])
            #expect(status == 0)
            let rows = try #require(try result(reply)["entries"] as? [[String: Any]])
            #expect(rows.count == 1 && rows[0]["language"] as? String == "und")
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    /// Fixed identities protect the published dry-run/commit contract when planning is split into helpers.
    @Test func planningPreservesExistingIdentitySeedsAndOutcomePaths() throws {
        let input = batch("stable-ids", [add(content: [["text": "Example content"]])])
        let decoded = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: input))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = try VocabularyCLIPlan(batch: decoded, snapshot: .init(revision: 0, document: .init()),
            fingerprint: "fixture", prepared: [:], now: now)
        let entry = try #require(plan.document.entries.first)
        let sense = try #require(entry.senses.first)
        #expect(entry.id.uuidString == "A316F899-6FA4-5BB7-A3FD-690B39CBE494")
        #expect(sense.id.uuidString == "B1FBB4CB-D6E5-506F-9D5D-5C307D9CBEF4")
        #expect(sense.examples.first?.id.uuidString == "6019CF31-390A-57AC-A0E9-1A85017573DE")
        #expect(sense.content?.first?.id.uuidString == "F0F952BC-AA29-55DA-B9AD-B75FC03874B4")
        #expect(entry.createdAt == now && sense.updatedAt == now)
        #expect(plan.outcomes == [.object([
            "operation": .integer(0), "entryID": .string(entry.id.uuidString),
            "senseID": .string(sense.id.uuidString), "createdEntry": .bool(true),
            "exampleIDs": .array([.string("6019CF31-390A-57AC-A0E9-1A85017573DE")]),
            "blockIDs": .array([.string("F0F952BC-AA29-55DA-B9AD-B75FC03874B4")])
        ])])
    }

    /// Explicit source reuse keeps the example and translations; text equality alone does not.
    @Test func sequentialPlanningRetainsExampleIdentityAndDeduplicatesVariants() throws {
        let seed = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: batch("seed", [add()])))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = try VocabularyCLIPlan(batch: seed, snapshot: .init(revision: 0, document: .init()),
            fingerprint: "fixture", prepared: [:], now: now)
        let entry = try #require(initial.document.entries.first)
        let sense = try #require(entry.senses.first)
        let usage = try #require(sense.examples.first)
        let variant: [String: Any] = [
            "text": usage.text, "sourceID": usage.sourceID.uuidString,
            "translation": "La banque est ouverte.", "translationLanguage": "fr"
        ]
        let input = batch("ordered", [
            ["update": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString,
                "expectedRevision": 7, "explanation": "Current usage explanation", "note": "After update"]],
            ["append": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString,
                "tags": ["finance", "finance"], "examples": [variant, variant, ["text": "We reached the bank."]]]]
        ])
        let decoded = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: input))
        let snapshot = VocabularySnapshot(revision: 7, document: initial.document)
        let plan = try VocabularyCLIPlan(batch: decoded, snapshot: snapshot, fingerprint: "fixture", prepared: [:], now: now)
        let updated = try #require(plan.document.entries.first?.senses.first)
        #expect(updated.id == sense.id && updated.note == "After update")
        #expect(updated.content?.count == 1)
        if case .text(let text) = updated.content?.first?.content {
            #expect(text.text == "Current usage explanation")
        } else { Issue.record("The revision-bound update must replace the canonical explanation") }
        #expect(updated.tags == ["finance"] && updated.examples.count == 2)
        #expect(updated.examples[0].id == usage.id && updated.examples[0].translation == usage.translation)
        #expect(updated.examples[0].translationVariants == [.init(text: "La banque est ouverte.", language: .french)])
        #expect(snapshot.document.entries[0].senses[0] == sense)
        #expect(plan.outcomes.count == 2)
    }

    @Test func addingAnotherSenseCannotStealAnExplicitSourceOccurrence() throws {
        let seed = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: batch("seed", [add()])))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = try VocabularyCLIPlan(batch: seed, snapshot: .init(revision: 0, document: .init()),
            fingerprint: "fixture", prepared: [:], now: now)
        var operation = add()
        var material = try #require(operation["add"] as? [String: Any])
        material["examples"] = [["text": "The bank is open.", "sourceID": initial.document.sources[0].id.uuidString]]
        operation["add"] = material
        let decoded = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: batch("another-sense", [operation])))
        do {
            _ = try VocabularyCLIPlan(batch: decoded, snapshot: .init(revision: 1, document: initial.document),
                fingerprint: "fixture", prepared: [:], now: now)
            Issue.record("An explicit source occurrence must remain with its current sense.")
        } catch let error as CLIError {
            #expect(error.code == .conflict)
            #expect(error.message.contains("belongs to another sense"))
        }
        #expect(initial.document.entries[0].senses.count == 1)
    }

    /// Revisions beyond Double's exact integer range must keep their integer representation on the wire.
    @Test func wireJSONPreservesIntegerRevisionsAndOtherValueKinds() throws {
        let data = Data(#"{"revision":9007199254740993,"enabled":true,"ratio":1.5,"items":[null,"word"]}"#.utf8)
        let expected = CLIJSON.object([
            "revision": .integer(9_007_199_254_740_993), "enabled": .bool(true),
            "ratio": .number(1.5), "items": .array([.null, .string("word")])
        ])
        let decoded = try JSONDecoder().decode(CLIJSON.self, from: data)
        #expect(decoded == expected)
        #expect(try JSONDecoder().decode(CLIJSON.self, from: JSONEncoder().encode(decoded)) == expected)
    }

    @Test func dryRunCommitReplayAndPortableReadUseOneTransactionAndRefreshStore() async throws {
        let fixture = try await Fixture()
        do {
            let png = fixture.directory.appendingPathComponent("image.png")
            try VocabularyImageTestFixture.png().write(to: png)
            let input = batch("first", [add(content: [["text": "A financial institution", "bold": true], ["image": ["path": png.path, "caption": "Example image"]]])])
            let dry = try await fixture.apply(input, dry: true)
            #expect(dry.0 == 0); #expect(try result(dry.1)["dryRun"] as? Bool == true)
            #expect(try await fixture.archive.load().document.entries.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(
                atPath: fixture.directory.appendingPathComponent("notebook.sqlite.media").path).isEmpty)
            let committed = try await fixture.apply(input)
            #expect(committed.0 == 0); #expect(fixture.store.entries.count == 1)
            let outcomes = try #require(try result(committed.1)["operations"] as? [[String: Any]])
            let dryOutcomes = try #require(try result(dry.1)["operations"] as? [[String: Any]])
            #expect(outcomes[0]["senseID"] as? String == dryOutcomes[0]["senseID"] as? String)
            let replayed = try await fixture.apply(input)
            #expect(replayed.0 == 0); #expect(try result(replayed.1)["replayed"] as? Bool == true)
            #expect(try await fixture.archive.load().revision == 1)
            let reopened = VocabularyArchive(url: fixture.directory.appendingPathComponent("notebook.sqlite"))
            #expect(try await reopened.load().document.entries == fixture.store.entries)
            let entry = try #require(fixture.store.entries.first)
            let listed = try await fixture.call(["vocab", "list", "--query", "financial", "--language", "en", "--limit", "1"])
            let page = try #require(try result(listed.1)["entries"] as? [[String: Any]])
            #expect(listed.0 == 0 && page.count == 1)
            #expect(page[0]["entryID"] as? String == entry.id.uuidString)
            #expect(page[0]["expressionTruncated"] as? Bool == false)
            let read = try await fixture.call(["vocab", "get", entry.id.uuidString])
            #expect(read.0 == 0); #expect(try result(read.1)["revision"] as? Int == 1)
            #expect(try result(read.1)["entry"] as? [String: Any] != nil)
            for part in ["requests", "working", "replies"] {
                #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent(part).path).isEmpty)
            }
        } catch { await fixture.close(); throw error }
        await fixture.close()
    }

    @Test func staleUpdatesAndReusedKeysFailWithoutLosingUserNotes() async throws {
        let fixture = try await Fixture()
        do {
            _ = try await fixture.apply(batch("initial", [add()]))
            let entry = try #require(fixture.store.entries.first), sense = try #require(entry.senses.first)
            let stale = batch("stale", [["update": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString, "expectedRevision": 0, "note": "Must fail"]]])
            #expect(try await fixture.apply(stale).0 == 4)
            #expect(fixture.store.entries[0].senses[0].note == "Agent material")
            let current = batch("update", [["update": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString, "expectedRevision": 1, "note": "User-approved change", "tags": ["finance"]]]])
            #expect(try await fixture.apply(current).0 == 0)
            #expect(fixture.store.entries[0].senses[0].note == "User-approved change")
            #expect(try await fixture.apply(batch("initial", [add("different")])).0 == 4)
            #expect(try await fixture.archive.load().revision == 2)
        } catch { await fixture.close(); throw error }; await fixture.close()
    }

    @Test func invalidLaterOperationAndReceiptFailureRollBackContentAndMedia() async throws {
        let fixture = try await Fixture()
        do {
            let missing = ["append": ["entryID": UUID().uuidString, "senseID": UUID().uuidString, "tags": ["missing"]]]
            #expect(try await fixture.apply(batch("atomic", [add(), missing])).0 == 3)
            #expect(fixture.store.entries.isEmpty)
            let database = try LingroveNotebookEngine(databaseURL: fixture.directory.appendingPathComponent("notebook.sqlite"),
                mediaDirectoryURL: fixture.directory.appendingPathComponent("notebook.sqlite.media"))
            defer { try? database.close() }
            _ = try database.core.executeScript(sql: "CREATE TRIGGER reject_receipt BEFORE INSERT ON notebook_cli_receipts BEGIN SELECT RAISE(ABORT,'fixture'); END", errorContext: "Install synthetic rejection")
            let png = fixture.directory.appendingPathComponent("image.png"); try VocabularyImageTestFixture.png().write(to: png)
            let material = batch("receipt", [add(content: [["image": ["path": png.path]]])])
            #expect(try await fixture.apply(material).0 == 7)
            #expect(try await fixture.archive.load().document.entries.isEmpty)
            #expect(try database.core.scalarInt(sql: "SELECT count(*) FROM notebook_cli_receipts", values: []) == 0)
            // Staged immutable bytes may be reused, but a rollback grants no workspace mapping,
            // document reference, journal or completed acknowledgement.
            #expect(try database.core.scalarInt(sql: "SELECT count(*) FROM notebook_media_assets", values: []) == 0)
            #expect(try database.core.scalarInt(sql: "SELECT count(*) FROM notebook_pending_transactions", values: []) == 0)
            _ = try database.core.executeScript(sql: "DROP TRIGGER reject_receipt", errorContext: "Remove synthetic rejection")
            #expect(try await fixture.apply(material).0 == 0)
            #expect(try database.core.scalarInt(sql: "SELECT count(*) FROM notebook_cli_receipts", values: []) == 1)
        } catch { await fixture.close(); throw error }; await fixture.close()
    }

    @Test func explicitSourceReuseRetainsTranslationVariantsAndRejectsAmbiguousRanges() async throws {
        let fixture = try await Fixture()
        do {
            _ = try await fixture.apply(batch("initial", [add()]))
            let entry = try #require(fixture.store.entries.first), sense = try #require(entry.senses.first)
            let extra = batch("fr", [["append": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString,
                "examples": [["text": "The bank is open.", "sourceID": sense.examples[0].sourceID.uuidString,
                    "translation": "La banque est ouverte.", "translationLanguage": "fr"]]]]])
            #expect(try await fixture.apply(extra).0 == 0); #expect(try await fixture.apply(extra).0 == 0)
            let usage = fixture.store.entries[0].senses[0].examples
            #expect(usage.count == 1 && usage[0].translation == "银行开门了。")
            #expect(usage[0].translationVariants == [.init(text: "La banque est ouverte.", language: .french)])
            let repeated = batch("repeated", [["add": ["expression": "know", "language": "en", "kind": "word", "meaning": "知道", "examples": [["text": "I know you know"]]]]])
            #expect(try await fixture.apply(repeated).0 == 2)
            #expect(fixture.store.entries.count == 1)
        } catch { await fixture.close(); throw error }; await fixture.close()
    }

    @Test func serverRestartAndOversizedResponseReturnStructuredResults() async throws {
        let fixture = try await Fixture(oversizedReply: true)
        do {
            let response = try await fixture.call(["status"])
            #expect(response.0 == 2); #expect(response.1["ok"] as? Bool == false)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("working").path).isEmpty)
            async let firstStop: Void = fixture.server.stop()
            async let secondStop: Void = fixture.server.stop()
            _ = await (firstStop, secondStop)
            try await fixture.server.start()
            #expect(try await fixture.call(["status"]).0 == 2)
        } catch { await fixture.close(); throw error }; await fixture.close()
    }

    @Test func parserAndInputRejectMisspellingsAndCountsBeforeFileIO() throws {
        #expect(throws: CLIError.self) { _ = try CLIArguments(["vocab", "apply", "--file", "--stdin"]) }
        #expect(throws: CLIError.self) { _ = try CLIArguments(["status", "--dry-run"]) }
        #expect(throws: CLIError.self) { _ = try CLIArguments(["--timeout", "nan", "status"]) }
        var value = add(); var fields = try #require(value["add"] as? [String: Any]); fields["notte"] = "Typo"; value["add"] = fields
        #expect(throws: CLIError.self) { _ = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: batch("typo", [value]))) }
        let oversized = batch("count", [add(content: Array(repeating: ["image": ["path": "/never/read"]], count: 65))])
        #expect(throws: CLIError.self) { _ = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: oversized)) }
        let ranges = Array(repeating: ["location": 0, "length": 1], count: 65)
        let tooManyRanges = batch("ranges", [["add": ["expression": "bank", "language": "en", "kind": "word", "meaning": "fixture",
            "examples": [["text": "bank", "ranges": ranges]], "content": [["image": ["path": "/never/read"]]]]]])
        #expect(throws: CLIError.self) { _ = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: tooManyRanges)) }
    }

    @Test func timedOutClientRemovesUnclaimedRequestAndInstalledLinkKeepsUserFiles() async throws {
        let fixture = try await Fixture()
        do {
            await fixture.server.stop()
            let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lingrove")
            let response = try await Self.run(tool, arguments: ["--app", fixture.app.path, "--no-launch", "--timeout", "1", "status"], stdin: nil)
            #expect(response.0 == 8)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("requests").path).isEmpty)
            let link = fixture.directory.appendingPathComponent("bin/lingrove")
            let installer = CLIInstallation(executable: tool, destination: link)
            try await installer.install(); #expect(await installer.isInstalled())
            try await installer.install()
            try FileManager.default.removeItem(at: link)
            let own = Data("unrelated user command".utf8); try own.write(to: link)
            await #expect(throws: CLIError.self) { try await installer.install() }
            #expect(try Data(contentsOf: link) == own)
        } catch { await fixture.close(); throw error }; await fixture.close()
    }

    @Test func oldSQLiteSchemaIsRejectedWithoutMigratingOrDeletingIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite")
        let database = try VocabularySQLiteDatabase(url: url)
        try database.connection.execute("PRAGMA user_version=2")
        await #expect(throws: LocalStoreError.self) { try await VocabularyArchive(url: url).load() }
        #expect(try database.connection.rows("PRAGMA user_version") == [[.integer(2)]])
    }

    @Test func utf16RangesSurviveAndObsoleteExampleMeaningsAreRejected() async throws {
        let fixture = try await Fixture()
        do {
            let input = batch("emoji", [["add": ["expression": "know", "language": "en", "kind": "word", "meaning": "知道",
                "examples": [["text": "👩🏽‍💻 I know you know", "ranges": [["location": 10, "length": 4]]]]]]])
            #expect(try await fixture.apply(input).0 == 0)
            let entry = try #require(fixture.store.entries.first), sense = try #require(entry.senses.first)
            #expect(sense.examples[0].ranges == [.init(NSRange(location: 10, length: 4))])
            let obsolete = batch("different-meaning", [["append": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString,
                "examples": [["text": "👩🏽‍💻 I know you know", "meaning": "另一份释义", "ranges": [["location": 10, "length": 4]]]]]]])
            #expect(try await fixture.apply(obsolete).0 == 2)
            #expect(fixture.store.entries[0].senses[0] == sense)
        } catch { await fixture.close(); throw error }; await fixture.close()
    }

    @Test func overlappingOccurrencesAndReadBudgetFailBeforeProjection() throws {
        let source = batch("overlap", [["add": ["expression": "ana", "language": "en", "kind": "word", "meaning": "fixture", "examples": [["text": "banana"]]]]])
        let decoded = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: source))
        #expect(throws: CLIError.self) {
            _ = try VocabularyCLIPlan(batch: decoded, snapshot: .init(revision: 0, document: .init()), fingerprint: "fixture", prepared: [:], now: Date())
        }
        let entry = try VocabularyExportTests().fixture().entries[0]
        try VocabularyCLIReadBudget.validate(entry)
        #expect(throws: CLIError.self) { try VocabularyCLIReadBudget.validate(entry, maximum: 4_096) }
    }
}
