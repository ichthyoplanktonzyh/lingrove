import Foundation
import Testing
@testable import Lingrove

/// Tests use the real bundled executable, passive mailbox server, shared UI store and private
/// SQLite file. A fake containing bundle chooses a disposable mailbox; --no-launch guarantees
/// these processes cannot launch or write the user's Dev/production notebook.
@Suite(.serialized)
@MainActor
struct VocabularyCLITests {
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
            #expect(try await fixture.call(["vocab", "capture", "--stdin"], stdin: bytes).0 == 0)
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
                            "associations": [["meaning": "finance", "usage": "the bank"]]],
                        ["meaning": "河岸", "examples": [["text": "We sat on the bank.", "translation": "我们坐在河岸上。"]],
                            "associations": [["meaning": "water"]]]
                    ]],
                    ["expression": "Could you", "kind": "pattern", "senses": [
                        ["meaning": "委婉请求", "examples": [["text": "Could you help me?", "translation": "你能帮我吗？"]],
                            "associations": [["meaning": "request", "usage": "Could you + verb?", "formality": "neutral"]]]
                    ]]
                ], "relations": [["from": "finance", "to": "water", "kind": "related", "note": "同形词，不是同义关系"]]]
            func capture(_ value: [String: Any], dry: Bool = false) async throws -> (Int32, [String: Any]) {
                try await fixture.call(["vocab", "capture", "--stdin"] + (dry ? ["--dry-run"] : []),
                    stdin: JSONSerialization.data(withJSONObject: value))
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
            #expect(document.collectedEntries.count == 2 && document.collections.count == 3)
            #expect(document.sources.count == 3 && document.occurrences.count == 3 && document.interpretations.count == 3)
            #expect(document.sources.allSatisfy { $0.kind == .generated })
            #expect(document.semantics.mappings.allSatisfy { $0.provenance.origin == .model && $0.provenance.status == .confirmed })
            #expect(document.semantics.patterns.allSatisfy { $0.provenance.status == .confirmed })
            #expect(document.semantics.mappings.last?.relation == .realizesFunction)
            #expect(document.occurrences.first?.ranges.first?.location == 7) // Emoji uses two UTF-16 code units.
            let matches = VocabularyMeaningBrowserProjection.items(index: document.semantics,
                entries: document.collectedEntries, query: "存钱的地方")
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
            let first = try #require(document.collectedEntries.first { $0.expression == "bank" })
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
            #expect(updated.collectedEntries.first { $0.id == first.id }?.senses.first { $0.id == sense.id }?.note == sense.note)
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

    @Test func externalAgentCanOrganizeUncollectedMaterialThenCollectAndUncollectIt() async throws {
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
                    "status": "accepted", "meaning": "推迟会议"]),
                put("interpretations", ["id": candidate, "occurrenceID": occurrence, "meaning": "抵制", "status": "candidate"]),
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
            #expect(fixture.store.entries.isEmpty)
            let catalog = try await fixture.call(["data", "get", "senses", sense])
            #expect(catalog.0 == 0)
            let unresolved = try await fixture.call(["data", "list", "interpretations", "--related", occurrence, "--status", "candidate"])
            #expect(unresolved.0 == 0)
            #expect(try result(unresolved.1)["total"] as? Int == 1)
            #expect(try await fixture.call(["vocab", "list"]).1["ok"] as? Bool == true)
            let collect = resourceBatch("collect", 1, [put("collections", ["senseID": sense, "interpretationIDs": [accepted],
                "note": "Personal note", "tags": ["scheduling"]])])
            #expect(try await fixture.apply(collect).0 == 0)
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
            let uncollect = resourceBatch("uncollect", 2, [["delete": ["resource": "collections", "id": sense]]])
            #expect(try await fixture.apply(uncollect).0 == 0)
            #expect(fixture.store.entries.isEmpty)
            let retained = try await fixture.archive.load()
            #expect(retained.document.sources.count == 1 && retained.document.interpretations.count == 2)
            #expect(retained.document.semantics.mappings[0].evidenceIDs.map(\.uuidString) == [accepted])
            #expect(retained.document.semantics.nodes[0].provenance == .init(origin: .model, status: .confirmed))
            #expect(retained.document.semantics.mappings[0].provenance.status == .confirmed)
            #expect(retained.document.semantics.cueTargets[0].provenance.status == .confirmed)
            #expect(try await fixture.call(["data", "get", "sources", source]).0 == 0)
            let traditional = batch("legacy-recollect", [["update": ["entryID": entry, "senseID": sense,
                "expectedRevision": 3, "note": "Collected through the traditional CLI"]]])
            #expect(try await fixture.apply(traditional).0 == 0)
            #expect(fixture.store.entries.first?.senses.first?.note == "Collected through the traditional CLI")
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
        init(oversizedReply: Bool = false) async throws {
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
            server = CLIMailboxServer(root: root) { request in
                if oversizedReply { return .init(requestID: request.id, ok: true, result: .string(String(repeating: "x", count: CLIInputPolicy.maximumBytes))) }
                return await store.executeCLI(request)
            }
            try await server.start()
        }
        func close() async {
            await server.stop()
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        func call(_ arguments: [String], stdin: Data? = nil) async throws -> (Int32, [String: Any]) {
            let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/lingrove")
            #expect(FileManager.default.isExecutableFile(atPath: tool.path))
            let result = try await VocabularyCLITests.run(tool, arguments: ["--app", app.path, "--no-launch", "--timeout", "5"] + arguments, stdin: stdin)
            let object = try #require(JSONSerialization.jsonObject(with: result.1) as? [String: Any])
            return (result.0, object)
        }
        func apply(_ object: [String: Any], dry: Bool = false) async throws -> (Int32, [String: Any]) {
            let data = try JSONSerialization.data(withJSONObject: object)
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
            "usageIDs": .array([.string("6019CF31-390A-57AC-A0E9-1A85017573DE")]),
            "blockIDs": .array([.string("F0F952BC-AA29-55DA-B9AD-B75FC03874B4")])
        ])])
    }

    /// Later operations see earlier changes, while repeated captures keep the saved usage and translations.
    @Test func sequentialPlanningRetainsUsageIdentityAndDeduplicatesVariants() throws {
        let seed = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: batch("seed", [add()])))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = try VocabularyCLIPlan(batch: seed, snapshot: .init(revision: 0, document: .init()),
            fingerprint: "fixture", prepared: [:], now: now)
        let entry = try #require(initial.document.entries.first)
        let sense = try #require(entry.senses.first)
        let usage = try #require(sense.examples.first)
        let variant: [String: Any] = [
            "text": usage.text, "translation": "La banque est ouverte.", "translationLanguage": "fr"
        ]
        let input = batch("ordered", [
            ["update": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString,
                "expectedRevision": 7, "note": "After update"]],
            ["append": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString,
                "tags": ["finance", "finance"], "examples": [variant, variant, ["text": "We reached the bank."]]]]
        ])
        let decoded = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: input))
        let snapshot = VocabularySnapshot(revision: 7, document: initial.document)
        let plan = try VocabularyCLIPlan(batch: decoded, snapshot: snapshot, fingerprint: "fixture", prepared: [:], now: now)
        let updated = try #require(plan.document.entries.first?.senses.first)
        #expect(updated.id == sense.id && updated.note == "After update")
        #expect(updated.tags == ["finance"] && updated.examples.count == 2)
        #expect(updated.examples[0].id == usage.id && updated.examples[0].translation == usage.translation)
        #expect(updated.examples[0].translationVariants == [.init(text: "La banque est ouverte.", language: .french)])
        #expect(snapshot.document.entries[0].senses[0] == sense)
        #expect(plan.outcomes.count == 2)
    }

    @Test func addingAnotherSenseCannotStealAnExistingUsage() throws {
        let seed = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: batch("seed", [add()])))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = try VocabularyCLIPlan(batch: seed, snapshot: .init(revision: 0, document: .init()),
            fingerprint: "fixture", prepared: [:], now: now)
        let decoded = try CLIInputPolicy.decode(JSONSerialization.data(withJSONObject: batch("another-sense", [add()])))
        do {
            _ = try VocabularyCLIPlan(batch: decoded, snapshot: .init(revision: 1, document: initial.document),
                fingerprint: "fixture", prepared: [:], now: now)
            Issue.record("An existing usage must remain with its current sense.")
        } catch let error as CLIError {
            #expect(error.code == .conflict)
            #expect(error.message == "This usage already belongs to another sense. Append to its current owner.")
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
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("notebook.sqlite.media").path))
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
            let database = try VocabularySQLiteDatabase(url: fixture.directory.appendingPathComponent("notebook.sqlite"))
            try database.connection.execute("CREATE TRIGGER reject_receipt BEFORE INSERT ON cli_receipts BEGIN SELECT RAISE(ABORT,'fixture'); END")
            let png = fixture.directory.appendingPathComponent("image.png"); try VocabularyImageTestFixture.png().write(to: png)
            let material = batch("receipt", [add(content: [["image": ["path": png.path]]])])
            #expect(try await fixture.apply(material).0 == 7)
            #expect(try await fixture.archive.load().document.entries.isEmpty)
            #expect(try database.connection.rows("SELECT count(*) FROM cli_receipts") == [[.integer(0)]])
            let media = fixture.directory.appendingPathComponent("notebook.sqlite.media")
            #expect((try? FileManager.default.contentsOfDirectory(atPath: media.path))?.isEmpty ?? true)
            try database.connection.execute("DROP TRIGGER reject_receipt")
            #expect(try await fixture.apply(material).0 == 0)
            #expect(try database.connection.rows("SELECT count(*) FROM cli_receipts") == [[.integer(1)]])
        } catch { await fixture.close(); throw error }; await fixture.close()
    }

    @Test func repeatedUsageRetainsTranslationVariantsAndRejectsMeaningConflicts() async throws {
        let fixture = try await Fixture()
        do {
            _ = try await fixture.apply(batch("initial", [add()]))
            let entry = try #require(fixture.store.entries.first), sense = try #require(entry.senses.first)
            let extra = batch("fr", [["append": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString,
                "examples": [["text": "The bank is open.", "translation": "La banque est ouverte.", "translationLanguage": "fr"]]]]])
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
        await #expect(throws: VocabularyError.unsupportedVersion) { try await VocabularyArchive(url: url).load() }
        #expect(try database.connection.rows("PRAGMA user_version") == [[.integer(2)]])
    }

    @Test func utf16RangesHandleEmojiAndAppendedMeaningConflictsAreExplicit() async throws {
        let fixture = try await Fixture()
        do {
            let input = batch("emoji", [["add": ["expression": "know", "language": "en", "kind": "word", "meaning": "知道",
                "examples": [["text": "👩🏽‍💻 I know you know", "meaning": "了解", "meaningLanguage": "zh-Hans",
                    "ranges": [["location": 10, "length": 4]]]]]]])
            #expect(try await fixture.apply(input).0 == 0)
            let entry = try #require(fixture.store.entries.first), sense = try #require(entry.senses.first)
            #expect(sense.examples[0].ranges == [.init(NSRange(location: 10, length: 4))])
            let conflict = batch("different-meaning", [["append": ["entryID": entry.id.uuidString, "senseID": sense.id.uuidString,
                "examples": [["text": "👩🏽‍💻 I know you know", "meaning": "不同的含义", "meaningLanguage": "zh-Hans", "ranges": [["location": 10, "length": 4]]]]]]])
            #expect(try await fixture.apply(conflict).0 == 4)
            #expect(fixture.store.entries[0].senses[0].examples[0].meaning == "了解")
            var cleared = fixture.store.entries[0]
            cleared.senses[0].examples[0].meaning = ""
            #expect(await fixture.store.update(cleared, basedOn: fixture.store.entries[0]))
            #expect(try await fixture.apply(conflict).0 == 4)
            #expect(fixture.store.entries[0].senses[0].examples[0].meaning.isEmpty)
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
