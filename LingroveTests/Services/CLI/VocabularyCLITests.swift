import Foundation
import Testing
@testable import Lingrove

/// Tests use the real bundled executable, passive mailbox server, shared UI store and private
/// SQLite file. A fake containing bundle chooses a disposable mailbox; --no-launch guarantees
/// these processes cannot launch or write the user's Dev/production notebook.
@Suite(.serialized)
@MainActor
struct VocabularyCLITests {
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

    @Test func acceptedSQLiteSchemaOneUpgradesWithoutReadingRetiredJSON() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notebook.sqlite"), retired = directory.appendingPathComponent("notebook-v3.json")
        let bytes = Data("Never imported".utf8); try bytes.write(to: retired)
        do {
            let database = try VocabularySQLiteDatabase(url: url)
            let document = VocabularyDocument(entries: try VocabularyExportTests().fixture().entries)
            _ = try database.write(document, previous: .init(), expectedRevision: 0)
            try database.connection.execute("DROP TABLE cli_receipts")
            try database.connection.execute("PRAGMA user_version=1")
            database.connection.close()
        }
        let archive = VocabularyArchive(url: url), snapshot = try await archive.load()
        #expect(snapshot.document.entries.count == 2 && snapshot.revision == 1)
        let database = try VocabularySQLiteDatabase(url: url)
        #expect(try database.connection.rows("PRAGMA user_version") == [[.integer(2)]])
        #expect(try database.connection.rows("SELECT count(*) FROM cli_receipts") == [[.integer(0)]])
        #expect(try Data(contentsOf: retired) == bytes)
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
