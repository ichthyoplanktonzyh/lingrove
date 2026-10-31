import CryptoKit
import Foundation
import LingroveNotebook
import LingroveNotebookSync
import Testing

/// Exercises the public transport boundary as one path: server-shaped rows,
/// ordered byte pages, verified records, a durable shadow, then the domain graph.
/// These tests deliberately use the projection fixture rather than constructing
/// isolated records that could never form a valid notebook.
struct VocabularyWireWindowIntegrationTests {
    private static let scope = VocabularyWireWindowScope(
        ownerUserID: "owner@example.test",
        workspaceID: VocabularyWireTestFixture.id(7001),
        notebookID: VocabularyWireTestFixture.notebookID,
        replicaID: VocabularyWireTestFixture.id(7002)
    )
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Server sequence strings preserve exact Int64 values above JavaScript precision")
    func sequenceUsesCanonicalInt64Strings() throws {
        let aboveSafeInteger = try VocabularyWireSequence("9007199254740993")
        #expect(aboveSafeInteger.rawValue == "9007199254740993")
        #expect(aboveSafeInteger > .zero)
        #expect(try JSONEncoder().encode(aboveSafeInteger) == Data("\"9007199254740993\"".utf8))

        let maximum = try VocabularyWireSequence("9223372036854775807")
        #expect(maximum.rawValue == "9223372036854775807")

        for invalid in ["", "00", "01", "+1", "-1", " 1", "9223372036854775808"] {
            #expect(throws: VocabularyWireWindowError.invalidRecord) {
                _ = try VocabularyWireSequence(invalid)
            }
        }
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(VocabularyWireSequence.self, from: Data("9007199254740993".utf8))
        }
    }

    @Test("Manifest and empty byte page match the Node 24 contract and encoder golden")
    func capturedNodeGoldenMatchesSwiftDecoder() throws {
        // Captured from the backend's actual contract.ts and CorpusWindowEncoder under Node
        // 24.22.1 and cross-checked under 24.19.0. Keeping it inline avoids a runtime Node dependency.
        let manifestData = Data(#"""
        {
          "protocolVersion": 1,
          "workspaceId": "00000000-0000-0000-0000-000000000101",
          "notebookId": "00000000-0000-0000-0000-000000000102",
          "replicaId": "00000000-0000-0000-0000-000000000103",
          "windowId": "00000000-0000-0000-0000-000000000104",
          "ownerUserId": "学:e\u0301\nowner",
          "mode": "bootstrap",
          "afterSequence": null,
          "highWaterSequence": "9223372036854775807",
          "initialized": false,
          "expiresAtMilliseconds": 1900000000000,
          "recordCount": 0,
          "pageCount": 1,
          "byteCount": 2,
          "pagesSha256": "ec03109533a50df73922b39ef03a6549d714ec79cd35283094988331be5ea425",
          "manifestSha256": "20cfda7cc6a28459e911e2dfefb6420f7518d7f2ef2e5ce72d6ec924fd8c27c2"
        }
        """#.utf8)
        let pageData = Data(#"""
        {"windowId":"00000000-0000-0000-0000-000000000104","ordinal":0,"encoding":"base64","data":"W10=","sha256":"4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945","byteCount":2}
        """#.utf8)
        let manifest = try JSONDecoder().decode(VocabularyWireWindowManifest.self, from: manifestData)
        let page = try JSONDecoder().decode(VocabularyWireWindowPage.self, from: pageData)
        #expect(try JSONDecoder().decode(VocabularyWireWindowManifest.self, from: JSONEncoder().encode(manifest)) == manifest)
        #expect(try JSONDecoder().decode(VocabularyWireWindowPage.self, from: JSONEncoder().encode(page)) == page)
        let scope = VocabularyWireWindowScope(
            ownerUserID: "学:e\u{0301}\nowner",
            workspaceID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000101")),
            notebookID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000102")),
            replicaID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000103"))
        )
        try manifest.validate(expecting: scope, now: Self.now)
        #expect(manifest.pagesSHA256 == "ec03109533a50df73922b39ef03a6549d714ec79cd35283094988331be5ea425")
        #expect(manifest.manifestSHA256 == "20cfda7cc6a28459e911e2dfefb6420f7518d7f2ef2e5ce72d6ec924fd8c27c2")

        var accumulator = try VocabularyWireWindowAccumulator(manifest: manifest, expecting: scope, now: Self.now)
        let checkedBytes = try accumulator.accept(page, now: Self.now)
        #expect(checkedBytes == Data("[]".utf8))
        let verified = try accumulator.finish(recordsJSON: checkedBytes, now: Self.now)
        #expect(verified.records.isEmpty)
        #expect(verified.manifest.highWaterSequence.rawValue == "9223372036854775807")
    }

    @Test("Manifest decoding rejects unknown keys, unsafe JSON counts, and invalid mode cursors")
    func manifestSchemaIsClosedAndBounded() throws {
        let built = try Self.window(records: [], scope: Self.scope, initialized: false)
        let base = try Self.jsonObject(built.manifestData)

        var unknown = base
        unknown["privateEndpoint"] = "must not cross the public contract"
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(VocabularyWireWindowManifest.self, from: Self.jsonData(unknown))
        }

        var unsafeCount = base
        unsafeCount["recordCount"] = NSNumber(value: 9_007_199_254_740_992)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(VocabularyWireWindowManifest.self, from: Self.jsonData(unsafeCount))
        }

        var badBootstrapCursor = base
        badBootstrapCursor["afterSequence"] = "0"
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(VocabularyWireWindowManifest.self, from: Self.jsonData(badBootstrapCursor))
        }

        var badDigest = base
        badDigest["manifestSha256"] = String(repeating: "0", count: 64)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(VocabularyWireWindowManifest.self, from: Self.jsonData(badDigest))
        }

        let composed = Self.scope(ownerUserID: "caf\u{00E9}")
        let decomposed = Self.scope(ownerUserID: "cafe\u{0301}")
        #expect(composed.ownerUserID == decomposed.ownerUserID) // Swift String equality uses canonical equivalence.
        #expect(composed != decomposed) // SQL TEXT identity is byte-for-byte in this protocol.

        let scopedWindow = try Self.window(records: [], scope: composed, initialized: false)
        try scopedWindow.manifest.validate(expecting: composed, now: Self.now)
        #expect(throws: VocabularyWireWindowError.scopeMismatch) {
            try scopedWindow.manifest.validate(expecting: decomposed, now: Self.now)
        }
        #expect(throws: VocabularyWireWindowError.expiredWindow) {
            try scopedWindow.manifest.validate(expecting: composed, now: Date(timeIntervalSince1970: 2_000_000_000))
        }
    }

    @Test("Page decoding and verification require canonical base64 and exact page metadata")
    func pageEncodingAndDigestAreStrict() throws {
        let built = try Self.window(records: [], scope: Self.scope, initialized: false)
        let valid = try #require(built.pages.first)

        var unknown = try Self.jsonObject(JSONEncoder().encode(valid))
        unknown["text"] = "an uncontracted alternate representation"
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(VocabularyWireWindowPage.self, from: Self.jsonData(unknown))
        }

        var wrongEncoding = try Self.jsonObject(JSONEncoder().encode(valid))
        wrongEncoding["encoding"] = "utf8"
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(VocabularyWireWindowPage.self, from: Self.jsonData(wrongEncoding))
        }

        let nonCanonical = try VocabularyWireWindowPage(
            windowID: valid.windowID, ordinal: 0, data: "W10", sha256: Self.sha256(Data("[]".utf8)), byteCount: 2
        )
        #expect(throws: VocabularyWireWindowError.invalidPage) {
            _ = try nonCanonical.verifiedBytes(for: built.manifest, expecting: Self.scope, now: Self.now)
        }

        let wrongHash = try VocabularyWireWindowPage(
            windowID: valid.windowID, ordinal: 0, data: valid.data,
            sha256: String(repeating: "0", count: 64), byteCount: valid.byteCount
        )
        #expect(throws: VocabularyWireWindowError.invalidPage) {
            _ = try wrongHash.verifiedBytes(for: built.manifest, expecting: Self.scope, now: Self.now)
        }

        let wrongWindow = try VocabularyWireWindowPage(
            windowID: VocabularyWireTestFixture.id(8001), ordinal: 0, data: valid.data,
            sha256: valid.sha256, byteCount: valid.byteCount
        )
        #expect(throws: VocabularyWireWindowError.invalidPage) {
            _ = try wrongWindow.verifiedBytes(for: built.manifest, expecting: Self.scope, now: Self.now)
        }
    }

    @Test("A complete window verifies ordered bytes before returning typed corpus rows")
    func accumulatorReturnsOnlyFullyCheckedRecords() throws {
        let document = try VocabularyWireTestFixture.document()
        let projection = try VocabularyWireProjectionCodec.project(document, notebookID: VocabularyWireTestFixture.notebookID)
        #expect(Set(projection.entities.map(\.entityType)) == Set(VocabularyWireEntityKind.allCases))

        let records = try Self.rows(from: projection.entities)
        let built = try Self.window(records: records, scope: Self.scope, initialized: true)
        var accumulator = try VocabularyWireWindowAccumulator(
            manifest: built.manifest, expecting: Self.scope, now: Self.now
        )
        var persistedBytes = Data()
        for page in built.pages {
            persistedBytes.append(try accumulator.accept(page, now: Self.now))
        }
        let verified = try accumulator.finish(recordsJSON: persistedBytes, now: Self.now)
        #expect(persistedBytes == built.recordsJSON)
        #expect(verified.records.count == projection.entities.count)
        #expect(Set(verified.records.map(\.entity.entityType)) == Set(VocabularyWireEntityKind.allCases))
        #expect(verified.records.allSatisfy { $0.version.rawValue == "1" })
        #expect(throws: VocabularyWireWindowError.incompleteWindow) {
            _ = try accumulator.finish(recordsJSON: persistedBytes, now: Self.now)
        }
    }

    @Test("The accumulator rejects missing pages, repeated or skipped ordinals, and expired leases")
    func accumulatorRequiresEveryLivePage() throws {
        let entityID = VocabularyWireTestFixture.id(8123).uuidString.lowercased()
        let prefix = "[{\"entityType\":\"retrievalCue\",\"entityId\":\"\(entityID)\",\"version\":\"1\",\"deleted\":false,\"fields\":{\"text\":\""
        let suffix = "\"},\"fieldVersions\":{\"text\":\"1\"},\"fieldResets\":{\"text\":\"1\"}}]"
        let padding = VocabularyWireWindowManifest.pageBytes - 1 - prefix.utf8.count
        let largeJSON = Data((prefix + String(repeating: "a", count: padding) + "é" + suffix).utf8)
        #expect(largeJSON[VocabularyWireWindowManifest.pageBytes - 1] == 0xC3)
        #expect(largeJSON[VocabularyWireWindowManifest.pageBytes] == 0xA9)
        let built = try Self.window(recordsJSON: largeJSON, recordCount: 1, scope: Self.scope, initialized: true)
        #expect(built.pages.count == 2)

        var missing = try VocabularyWireWindowAccumulator(manifest: built.manifest, expecting: Self.scope, now: Self.now)
        _ = try missing.accept(built.pages[0], now: Self.now)
        #expect(throws: VocabularyWireWindowError.incompleteWindow) {
            _ = try missing.finish(recordsJSON: largeJSON, now: Self.now)
        }

        var skipped = try VocabularyWireWindowAccumulator(manifest: built.manifest, expecting: Self.scope, now: Self.now)
        #expect(throws: VocabularyWireWindowError.invalidPage) {
            _ = try skipped.accept(built.pages[1], now: Self.now)
        }

        var repeated = try VocabularyWireWindowAccumulator(manifest: built.manifest, expecting: Self.scope, now: Self.now)
        _ = try repeated.accept(built.pages[0], now: Self.now)
        #expect(throws: VocabularyWireWindowError.invalidPage) {
            _ = try repeated.accept(built.pages[0], now: Self.now)
        }

        var expired = try VocabularyWireWindowAccumulator(manifest: built.manifest, expecting: Self.scope, now: Self.now)
        #expect(throws: VocabularyWireWindowError.expiredWindow) {
            _ = try expired.accept(built.pages[0], now: Date(timeIntervalSince1970: 2_000_000_000))
        }

        var expiryDuringTransfer = try VocabularyWireWindowAccumulator(
            manifest: built.manifest, expecting: Self.scope, now: Self.now
        )
        _ = try expiryDuringTransfer.accept(built.pages[0], now: Self.now)
        #expect(throws: VocabularyWireWindowError.expiredWindow) {
            _ = try expiryDuringTransfer.finish(
                recordsJSON: largeJSON, now: Date(timeIntervalSince1970: 2_000_000_000)
            )
        }

        var complete = try VocabularyWireWindowAccumulator(manifest: built.manifest, expecting: Self.scope, now: Self.now)
        var restoredBytes = Data()
        for page in built.pages { restoredBytes.append(try complete.accept(page, now: Self.now)) }
        let verified = try complete.finish(recordsJSON: restoredBytes, now: Self.now)
        #expect(verified.records.count == 1)
        #expect(restoredBytes == largeJSON)
    }

    @Test("The accumulator catches aggregate hash, byte-count, and decoded record-count mismatches")
    func accumulatorChecksWholeWindowMetadata() throws {
        let built = try Self.window(records: [], scope: Self.scope, initialized: false)

        let altered = try Self.rebuildManifest(from: built.manifestData) { $0["pagesSha256"] = String(repeating: "0", count: 64) }
        var wrongAggregate = try VocabularyWireWindowAccumulator(manifest: altered, expecting: Self.scope, now: Self.now)
        _ = try wrongAggregate.accept(built.pages[0], now: Self.now)
        #expect(throws: VocabularyWireWindowError.incompleteWindow) {
            _ = try wrongAggregate.finish(recordsJSON: built.recordsJSON, now: Self.now)
        }
        #expect(throws: VocabularyWireWindowError.invalidPage) {
            _ = try wrongAggregate.accept(built.pages[0], now: Self.now)
        }
        #expect(try Self.verify(built).records.isEmpty)

        let wrongBytes = try Self.rebuildManifest(from: built.manifestData) { $0["byteCount"] = 3 }
        var byteAccumulator = try VocabularyWireWindowAccumulator(manifest: wrongBytes, expecting: Self.scope, now: Self.now)
        #expect(throws: VocabularyWireWindowError.invalidPage) {
            _ = try byteAccumulator.accept(built.pages[0], now: Self.now)
        }
        let wrongCount = try Self.rebuildManifest(from: built.manifestData) { $0["recordCount"] = 1 }
        var countAccumulator = try VocabularyWireWindowAccumulator(manifest: wrongCount, expecting: Self.scope, now: Self.now)
        let countPage = try VocabularyWireWindowPage(
            windowID: built.pages[0].windowID, ordinal: 0, data: built.pages[0].data,
            sha256: built.pages[0].sha256, byteCount: built.pages[0].byteCount
        )
        _ = try countAccumulator.accept(countPage, now: Self.now)
        #expect(throws: VocabularyWireWindowError.invalidRecord) {
            _ = try countAccumulator.finish(recordsJSON: built.recordsJSON, now: Self.now)
        }

        let repeatedRow = Self.row(
            entityType: "retrievalCue", entityID: VocabularyWireTestFixture.id(8124).uuidString.lowercased(),
            version: "1", fields: ["text": "duplicate identity"],
            fieldVersions: ["text": "1"], fieldResets: ["text": "1"]
        )
        let duplicateWindow = try Self.window(
            records: [repeatedRow, repeatedRow], scope: Self.scope, initialized: true
        )
        var duplicateAccumulator = try VocabularyWireWindowAccumulator(
            manifest: duplicateWindow.manifest, expecting: Self.scope, now: Self.now
        )
        _ = try duplicateAccumulator.accept(duplicateWindow.pages[0], now: Self.now)
        #expect(throws: VocabularyWireWindowError.duplicateRecord) {
            _ = try duplicateAccumulator.finish(recordsJSON: duplicateWindow.recordsJSON, now: Self.now)
        }
    }

    @Test("Corpus records reject unknown keys, unsupported types, bad composite identity, and invalid clocks")
    func corpusRecordMetadataIsStrict() throws {
        let entity = VocabularyWireEntity(
            entityType: .selectedInterpretation,
            entityID: "00000000-0000-0000-0000-000000000001:00000000-0000-0000-0000-000000000002",
            fields: ["senseId": .string("00000000-0000-0000-0000-000000000001"),
                     "interpretationId": .string("00000000-0000-0000-0000-000000000002")]
        )
        let valid = try Self.row(from: entity)
        _ = try Self.decodeRecord(valid)
        _ = try Self.decodeRecord(Self.tombstone(
            entityType: "categoryOverride", entityID: "00000000-0000-0000-0000-000000000003", version: "1"
        ))

        let newlineTombstone = Self.tombstone(
            entityType: "categoryOverride", entityID: "00000000-0000-0000-0000-000000000003\n", version: "1"
        )
        #expect(throws: VocabularyWireWindowError.invalidRecord) {
            _ = try Self.decodeRecord(newlineTombstone)
        }

        let deletedRoot = Self.tombstone(
            entityType: "notebookSettings",
            entityID: VocabularyWireTestFixture.notebookID.uuidString.lowercased(), version: "1"
        )
        #expect(throws: VocabularyWireWindowError.invalidRecord) {
            _ = try Self.decodeRecord(deletedRoot)
        }

        var futureClock = valid
        futureClock["version"] = "9007199254740993"
        futureClock["fieldVersions"] = ["senseId": "9007199254740993", "interpretationId": "9007199254740993"]
        futureClock["fieldResets"] = ["senseId": "9007199254740993", "interpretationId": "9007199254740993"]
        let exactFutureRecord = try Self.decodeRecord(futureClock)
        #expect(exactFutureRecord.version.rawValue == "9007199254740993")
        #expect(exactFutureRecord.fieldVersions["senseId"]?.rawValue == "9007199254740993")
        #expect(try JSONDecoder().decode(
            VocabularyWireCorpusRecord.self, from: JSONEncoder().encode(exactFutureRecord)
        ) == exactFutureRecord)

        var unknown = valid
        unknown["debugLabel"] = "private"
        #expect(throws: VocabularyWireError.invalidRecord) {
            _ = try Self.decodeRecord(unknown)
        }

        var unsupported = valid
        unsupported["entityType"] = "localAnkiBinding"
        #expect(throws: VocabularyWireWindowError.invalidRecord) {
            _ = try Self.decodeRecord(unsupported)
        }

        var wrongComposite = valid
        wrongComposite["entityId"] = "00000000-0000-0000-0000-000000000003:00000000-0000-0000-0000-000000000002"
        #expect(throws: VocabularyWireWindowError.invalidRecord) {
            _ = try Self.decodeRecord(wrongComposite)
        }

        var missingClock = valid
        var clocks = try Self.dictionary(missingClock["fieldVersions"])
        clocks.removeValue(forKey: "senseId")
        missingClock["fieldVersions"] = clocks
        #expect(throws: VocabularyWireWindowError.invalidRecord) {
            _ = try Self.decodeRecord(missingClock)
        }

        var clockPastVersion = valid
        clockPastVersion["fieldVersions"] = ["senseId": "2", "interpretationId": "1"]
        #expect(throws: VocabularyWireWindowError.invalidRecord) {
            _ = try Self.decodeRecord(clockPastVersion)
        }

        var zeroVersion = valid
        zeroVersion["version"] = "0"
        #expect(throws: VocabularyWireWindowError.invalidRecord) {
            _ = try Self.decodeRecord(zeroVersion)
        }

        var deletedWithFields = valid
        deletedWithFields["deleted"] = true
        #expect(throws: VocabularyWireWindowError.invalidRecord) {
            _ = try Self.decodeRecord(deletedWithFields)
        }
    }

    @Test("A verified full graph crosses the server shadow and retains private Anki and audio state")
    func completeGraphRoundTripsThroughTransportAndShadow() throws {
        let original = try VocabularyWireTestFixture.document()
        let projection = try VocabularyWireProjectionCodec.project(original, notebookID: VocabularyWireTestFixture.notebookID)
        let built = try Self.window(records: Self.rows(from: projection.entities), scope: Self.scope, initialized: true)
        let remoteBytes = try #require(String(data: built.recordsJSON, encoding: .utf8))
        #expect(!remoteBytes.contains("http://localhost:8765"))
        #expect(!remoteBytes.contains(VocabularyWireTestFixture.currentReceiptFingerprint))
        #expect(!remoteBytes.contains(VocabularyWireTestFixture.currentReceiptFilename))
        let verified = try Self.verify(built)

        let shadow = try VocabularyWireServerShadow.empty(scope: Self.scope).applying(verified, now: Self.now)
        let result = try shadow.materialize(preserving: projection.privateState)
        #expect(result.document == original)
        #expect(result.unattachedPrivateState.reviews.isEmpty)
        #expect(result.unattachedPrivateState.explanations.isEmpty)

        let review = try #require(result.document.collections.first { $0.senseID == VocabularyWireTestFixture.targetSenseID }?.review)
        #expect(review.bindings.map(\.id) == [
            VocabularyWireTestFixture.currentBindingID,
            VocabularyWireTestFixture.mergedBindingID
        ])
        #expect(review.activeBindingID == VocabularyWireTestFixture.mergedBindingID)
        let receiptFilenames = (review.plan.audioReceipts?.values.map(\.filename) ?? []) +
            review.preservedPlans.flatMap { $0.audioReceipts?.values.map(\.filename) ?? [] }
        #expect(Set(receiptFilenames) == Set([
            VocabularyWireTestFixture.currentReceiptFilename,
            VocabularyWireTestFixture.preservedReceiptFilename
        ]))
    }

    @Test("Empty and uninitialized windows preserve initialized books and reject materialization")
    func emptyIncrementalWindowPreservesShadow() throws {
        let projection = try VocabularyWireProjectionCodec.project(
            VocabularyWireTestFixture.document(), notebookID: VocabularyWireTestFixture.notebookID
        )
        let initial = try Self.verify(Self.window(
            records: Self.rows(from: projection.entities), scope: Self.scope, initialized: true
        ))
        let shadow = try VocabularyWireServerShadow.empty(scope: Self.scope).applying(initial, now: Self.now)

        let empty = try Self.window(
            recordsJSON: Data("[]".utf8), recordCount: 0, scope: Self.scope,
            mode: .incremental, afterSequence: "1", highWaterSequence: "1", initialized: true
        )
        #expect(empty.pages.count == 1)
        #expect(empty.pages[0].byteCount == 2)
        #expect(try shadow.applying(Self.verify(empty), now: Self.now).records == shadow.records)

        let uninitializedWindow = try Self.verify(Self.window(records: [], scope: Self.scope, initialized: false))
        let uninitialized = try VocabularyWireServerShadow.empty(scope: Self.scope)
            .applying(uninitializedWindow, now: Self.now)
        #expect(throws: VocabularyWireWindowError.uninitializedNotebook) {
            _ = try uninitialized.materialize()
        }
        #expect(throws: VocabularyWireWindowError.expiredWindow) {
            _ = try shadow.applying(uninitializedWindow, now: Date(timeIntervalSince1970: 2_000_000_000))
        }
        #expect(throws: VocabularyWireWindowError.invalidShadow) {
            _ = try shadow.applying(uninitializedWindow, now: Self.now)
        }
    }

    @Test("Bootstrap cannot omit known tombstones, roll records backward, or revive deleted identities")
    func bootstrapPreservesIdentityAndTombstones() throws {
        let projection = try VocabularyWireProjectionCodec.project(
            VocabularyWireTestFixture.document(), notebookID: VocabularyWireTestFixture.notebookID
        )
        let liveRows = try Self.rows(from: projection.entities)
        let tombstoneID = "00000000-0000-0000-0000-000000009999"
        let tombstone = Self.tombstone(entityType: "categoryOverride", entityID: tombstoneID, version: "1")
        let knownRows = liveRows.map { row -> [String: Any] in
            var copy = row
            if copy["entityType"] as? String == "entry" { copy["version"] = "2" }
            return copy
        } + [tombstone]
        let known = try VocabularyWireServerShadow(
            scope: Self.scope, sequence: try VocabularyWireSequence("2"), initialized: true,
            records: try Self.decodeRecords(Self.recordsJSON(knownRows))
        )
        let replayed = try known.applying(Self.verify(Self.window(
            records: knownRows, scope: Self.scope, highWaterSequence: "2", initialized: true
        )), now: Self.now)
        #expect(replayed.records.contains { $0.entity.entityID == tombstoneID && $0.deleted })

        let omitted = try Self.verify(Self.window(
            records: Array(knownRows.dropLast()), scope: Self.scope, highWaterSequence: "2", initialized: true
        ))
        #expect(throws: VocabularyWireWindowError.invalidShadow) {
            _ = try known.applying(omitted, now: Self.now)
        }

        let rolledBack = try Self.verify(Self.window(
            records: liveRows + [tombstone], scope: Self.scope, highWaterSequence: "2", initialized: true
        ))
        #expect(throws: VocabularyWireWindowError.invalidShadow) {
            _ = try known.applying(rolledBack, now: Self.now)
        }

        let revivedRows = Array(knownRows.dropLast()) + [Self.row(
            entityType: "categoryOverride", entityID: tombstoneID, version: "2", deleted: false,
            fields: ["labels": NSNull(), "definition": NSNull(), "examples": NSNull(), "scopeNote": NSNull(),
                     "references": NSNull(), "localizations": NSNull(), "isHidden": false],
            fieldVersions: ["labels": "2", "definition": "2", "examples": "2", "scopeNote": "2",
                            "references": "2", "localizations": "2", "isHidden": "2"],
            fieldResets: ["labels": "2", "definition": "2", "examples": "2", "scopeNote": "2",
                          "references": "2", "localizations": "2", "isHidden": "2"]
        )]
        let revived = try Self.verify(Self.window(
            records: revivedRows, scope: Self.scope, highWaterSequence: "2", initialized: true
        ))
        #expect(throws: VocabularyWireWindowError.invalidShadow) {
            _ = try known.applying(revived, now: Self.now)
        }
    }

    @Test("Incremental windows require the exact shadow base and monotonic field and reset clocks")
    func deltaRequiresBaseAndMonotonicClocks() throws {
        let projection = try VocabularyWireProjectionCodec.project(
            VocabularyWireTestFixture.document(), notebookID: VocabularyWireTestFixture.notebookID
        )
        let rows = try Self.rows(from: projection.entities)
        let shadow = try VocabularyWireServerShadow(
            scope: Self.scope, sequence: try VocabularyWireSequence("2"), initialized: true,
            records: try Self.decodeRecords(Self.recordsJSON(rows.map { row in
                var copy = row
                if copy["entityType"] as? String == "entry" {
                    copy["version"] = "2"
                    copy["fieldVersions"] = ["expression": "2", "dictionaryForm": "1", "language": "1", "kind": "1", "createdAt": "1", "updatedAt": "1", "rank": "1"]
                    copy["fieldResets"] = ["expression": "2", "dictionaryForm": "1", "language": "1", "kind": "1", "createdAt": "1", "updatedAt": "1", "rank": "1"]
                }
                return copy
            }))
        )

        let sourceEntry = try #require(rows.first {
            $0["entityType"] as? String == "entry" &&
                $0["entityId"] as? String == VocabularyWireTestFixture.targetEntryID.uuidString.lowercased()
        })
        let identity = try #require(sourceEntry["entityId"] as? String)
        let fields = try Self.dictionary(sourceEntry["fields"])
        let fieldNames = try Self.stringDictionary(sourceEntry["fieldVersions"]).keys.sorted()

        var staleBase = Self.row(entityType: "entry", entityID: identity, version: "3", fields: fields,
                                 fieldVersions: Dictionary(uniqueKeysWithValues: fieldNames.map { ($0, "3") }),
                                 fieldResets: Dictionary(uniqueKeysWithValues: fieldNames.map { ($0, "3") }))
        staleBase["fields"] = fields
        let wrongBase = try Self.verify(Self.window(
            records: [staleBase], scope: Self.scope, mode: .incremental,
            afterSequence: "1", highWaterSequence: "3", initialized: true
        ))
        #expect(throws: VocabularyWireWindowError.cursorMismatch) {
            _ = try shadow.applying(wrongBase, now: Self.now)
        }

        for (versions, resets) in [
            (["expression": "1"], ["expression": "1"]),
            (["expression": "2"], ["expression": "1"])
        ] {
            var clocks = try Self.stringDictionary(sourceEntry["fieldVersions"])
            var resetClocks = try Self.stringDictionary(sourceEntry["fieldResets"])
            clocks["expression"] = versions["expression"]
            resetClocks["expression"] = resets["expression"]
            let candidate = Self.row(
                entityType: "entry", entityID: identity, version: "3", fields: fields,
                fieldVersions: clocks, fieldResets: resetClocks
            )
            let window = try Self.verify(Self.window(
                records: [candidate], scope: Self.scope, mode: .incremental,
                afterSequence: "2", highWaterSequence: "3", initialized: true
            ))
            #expect(throws: VocabularyWireWindowError.invalidShadow) {
                _ = try shadow.applying(window, now: Self.now)
            }
        }

        // Editing an expression also requires replacing its saved explanation
        // inputs. An independent note edit exercises clocks without constructing
        // a graph the real typed writer would reject for stale explanations.
        let collection = try #require(rows.first { $0["entityType"] as? String == "collection" })
        let collectionID = try Self.string(collection["entityId"])
        let changedFields = try Self.dictionary(collection["fields"]).merging(["note": "changed on server"]) { _, new in new }
        var advancedVersions = try Self.stringDictionary(collection["fieldVersions"])
        var advancedResets = try Self.stringDictionary(collection["fieldResets"])
        advancedVersions["note"] = "3"
        advancedResets["note"] = "3"
        let validDelta = try Self.verify(Self.window(records: [Self.row(
            entityType: "collection", entityID: collectionID, version: "3", fields: changedFields,
            fieldVersions: advancedVersions, fieldResets: advancedResets
        )], scope: Self.scope, mode: .incremental, afterSequence: "2", highWaterSequence: "3", initialized: true))
        let updated = try shadow.applying(validDelta, now: Self.now).materialize().document
        #expect(updated.collections.first { $0.senseID.uuidString.lowercased() == collectionID }?.note == "changed on server")
        try Self.assertUnchangedClockRejectsCanonicalEquivalentText(in: rows)
    }

    @Test("Incremental windows cannot resurrect a tombstone")
    func deltaCannotReviveTombstone() throws {
        let projection = try VocabularyWireProjectionCodec.project(
            VocabularyWireTestFixture.document(), notebookID: VocabularyWireTestFixture.notebookID
        )
        let rows = try Self.rows(from: projection.entities)
        let categoryOverride = try #require(rows.first { $0["entityType"] as? String == "categoryOverride" })
        let overrideID = try #require(categoryOverride["entityId"] as? String)
        let otherRows = rows.filter { !($0["entityType"] as? String == "categoryOverride" && $0["entityId"] as? String == overrideID) }
        let tombstoned = otherRows + [Self.tombstone(entityType: "categoryOverride", entityID: overrideID, version: "2")]
        let shadow = try VocabularyWireServerShadow(
            scope: Self.scope, sequence: try VocabularyWireSequence("2"), initialized: true,
            records: try Self.decodeRecords(Self.recordsJSON(tombstoned))
        )

        var revived = categoryOverride
        revived["version"] = "3"
        revived["fieldVersions"] = try Self.stringDictionary(categoryOverride["fieldVersions"]).mapValues { _ in "3" }
        revived["fieldResets"] = try Self.stringDictionary(categoryOverride["fieldResets"]).mapValues { _ in "3" }
        let window = try Self.verify(Self.window(
            records: [revived], scope: Self.scope, mode: .incremental,
            afterSequence: "2", highWaterSequence: "3", initialized: true
        ))
        #expect(throws: VocabularyWireWindowError.invalidShadow) {
            _ = try shadow.applying(window, now: Self.now)
        }
    }
}

private extension VocabularyWireWindowIntegrationTests {
    static func assertUnchangedClockRejectsCanonicalEquivalentText(in rows: [[String: Any]]) throws {
        let nfc = "caf\u{00E9}"
        let nfd = "cafe\u{0301}"
        #expect(nfc == nfd)
        #expect(Data(nfc.utf8) != Data(nfd.utf8))

        let originalEntry = try #require(rows.first {
            $0["entityType"] as? String == "collection" &&
                $0["entityId"] as? String == VocabularyWireTestFixture.targetSenseID.uuidString.lowercased()
        })
        let identity = try #require(originalEntry["entityId"] as? String)
        let fields = try Self.dictionary(originalEntry["fields"])
        var baselineFields = fields
        baselineFields["note"] = nfc
        var baselineVersions = try Self.stringDictionary(originalEntry["fieldVersions"])
        var baselineResets = try Self.stringDictionary(originalEntry["fieldResets"])
        baselineVersions["note"] = "2"
        baselineResets["note"] = "1"

        let baselineRows = rows.map { row -> [String: Any] in
            guard row["entityType"] as? String == "collection", row["entityId"] as? String == identity else { return row }
            var copy = row
            copy["version"] = "2"
            copy["fields"] = baselineFields
            copy["fieldVersions"] = baselineVersions
            copy["fieldResets"] = baselineResets
            return copy
        }
        let shadow = try VocabularyWireServerShadow(
            scope: Self.scope, sequence: try VocabularyWireSequence("2"), initialized: true,
            records: try Self.decodeRecords(Self.recordsJSON(baselineRows))
        )

        var advancedReset = baselineResets
        advancedReset["note"] = "2"
        let resetOnlyRewrite = Self.row(
            entityType: "collection", entityID: identity, version: "3", fields: baselineFields,
            fieldVersions: baselineVersions, fieldResets: advancedReset
        )
        let resetOnlyWindow = try Self.verify(Self.window(
            records: [resetOnlyRewrite], scope: Self.scope, mode: .incremental,
            afterSequence: "2", highWaterSequence: "3", initialized: true
        ))
        #expect(throws: VocabularyWireWindowError.invalidShadow) {
            _ = try shadow.applying(resetOnlyWindow, now: Self.now)
        }

        var rewrittenFields = baselineFields
        rewrittenFields["note"] = nfd
        let rewritten = Self.row(
            entityType: "collection", entityID: identity, version: "3", fields: rewrittenFields,
            fieldVersions: baselineVersions, fieldResets: baselineResets
        )
        let window = try Self.verify(Self.window(
            records: [rewritten], scope: Self.scope, mode: .incremental,
            afterSequence: "2", highWaterSequence: "3", initialized: true
        ))
        #expect(throws: VocabularyWireWindowError.invalidShadow) {
            _ = try shadow.applying(window, now: Self.now)
        }
    }
    struct BuiltWindow {
        let manifest: VocabularyWireWindowManifest
        let manifestData: Data
        let pages: [VocabularyWireWindowPage]
        let recordsJSON: Data
    }

    static func scope(ownerUserID: String) -> VocabularyWireWindowScope {
        VocabularyWireWindowScope(ownerUserID: ownerUserID, workspaceID: Self.scope.workspaceID,
                                  notebookID: Self.scope.notebookID, replicaID: Self.scope.replicaID)
    }

    static func rows(from entities: [VocabularyWireEntity]) throws -> [[String: Any]] {
        try entities.sorted {
            ($0.entityType.rawValue + ":" + $0.entityID) < ($1.entityType.rawValue + ":" + $1.entityID)
        }.map { try row(from: $0) }
    }

    static func row(from entity: VocabularyWireEntity, version: String = "1") throws -> [String: Any] {
        let fieldsData = try JSONEncoder.wireEncoder().encode(entity.fields)
        let fields = try #require(JSONSerialization.jsonObject(with: fieldsData) as? [String: Any])
        let clocks = Dictionary(uniqueKeysWithValues: fields.keys.map { ($0, version) })
        return row(entityType: entity.entityType.rawValue, entityID: entity.entityID, version: version,
                   fields: fields, fieldVersions: clocks, fieldResets: clocks)
    }

    static func row(
        entityType: String, entityID: String, version: String, deleted: Bool = false,
        fields: [String: Any], fieldVersions: [String: String], fieldResets: [String: String]
    ) -> [String: Any] {
        ["entityType": entityType, "entityId": entityID, "version": version, "deleted": deleted,
         "fields": fields, "fieldVersions": fieldVersions, "fieldResets": fieldResets]
    }

    static func tombstone(entityType: String, entityID: String, version: String) -> [String: Any] {
        row(entityType: entityType, entityID: entityID, version: version, deleted: true,
            fields: [:], fieldVersions: [:], fieldResets: [:])
    }

    static func recordsJSON(_ records: [[String: Any]]) throws -> Data {
        var fragments = [String]()
        let orderedRecords = try records.map { record -> (key: String, value: [String: Any]) in
            let key = try string(record["entityType"]) + ":" + string(record["entityId"])
            return (key, record)
        }.sorted { $0.key < $1.key }
        for (_, record) in orderedRecords {
            // The backend constructs CorpusRecord properties in this order. Sorting nested
            // field objects and matching its C-collated identity order keep test bytes stable.
            let entityType = try string(record["entityType"])
            let entityID = try string(record["entityId"])
            let version = try string(record["version"])
            let deleted = try #require(record["deleted"])
            let fields = try dictionary(record["fields"])
            let fieldVersions = try dictionary(record["fieldVersions"])
            let fieldResets = try dictionary(record["fieldResets"])
            let values: [(String, Any)] = [
                ("entityType", entityType), ("entityId", entityID),
                ("version", version), ("deleted", deleted),
                ("fields", fields), ("fieldVersions", fieldVersions),
                ("fieldResets", fieldResets)
            ]
            let fieldsData = try JSONSerialization.data(withJSONObject: values[4].1, options: [.sortedKeys])
            let versionsData = try JSONSerialization.data(withJSONObject: values[5].1, options: [.sortedKeys])
            let resetsData = try JSONSerialization.data(withJSONObject: values[6].1, options: [.sortedKeys])
            fragments.append("{\"entityType\":\(try jsonString(values[0].1)),\"entityId\":\(try jsonString(values[1].1)),\"version\":\(try jsonString(values[2].1)),\"deleted\":\(try jsonBool(values[3].1)),\"fields\":\(String(decoding: fieldsData, as: UTF8.self)),\"fieldVersions\":\(String(decoding: versionsData, as: UTF8.self)),\"fieldResets\":\(String(decoding: resetsData, as: UTF8.self))}")
        }
        return Data(("[" + fragments.joined(separator: ",") + "]").utf8)
    }

    static func window(
        records: [[String: Any]], scope: VocabularyWireWindowScope, mode: VocabularyWireWindowManifest.Mode = .bootstrap,
        afterSequence: String? = nil, highWaterSequence: String = "1", initialized: Bool,
        now: Date = Self.now
    ) throws -> BuiltWindow {
        try window(recordsJSON: recordsJSON(records), recordCount: records.count, scope: scope, mode: mode,
                   afterSequence: afterSequence, highWaterSequence: highWaterSequence, initialized: initialized, now: now)
    }

    static func window(
        recordsJSON: Data, recordCount: Int, scope: VocabularyWireWindowScope, mode: VocabularyWireWindowManifest.Mode = .bootstrap,
        afterSequence: String? = nil, highWaterSequence: String = "1", initialized: Bool,
        now: Date = Self.now
    ) throws -> BuiltWindow {
        let rawPages = stride(from: 0, to: max(recordsJSON.count, 1), by: VocabularyWireWindowManifest.pageBytes).map { start in
            let end = min(start + VocabularyWireWindowManifest.pageBytes, recordsJSON.count)
            return recordsJSON.subdata(in: start..<end)
        }
        let pageDigests = rawPages.map(sha256)
        let descriptors = rawPages.enumerated().map { ordinal, bytes in
            "\(ordinal):\(pageDigests[ordinal]):\(bytes.count)\n"
        }.joined()
        let pagesSHA256 = sha256(Data(descriptors.utf8))
        let expires = Int(now.timeIntervalSince1970 * 1000) + 900_000
        let windowID = VocabularyWireTestFixture.id(9000)
        let afterValue: Any = afterSequence.map { $0 as Any } ?? NSNull()
        let manifestFields: [String: Any] = [
            "protocolVersion": 1,
            "workspaceId": scope.workspaceID.uuidString.lowercased(),
            "notebookId": scope.notebookID.uuidString.lowercased(),
            "replicaId": scope.replicaID.uuidString.lowercased(),
            "windowId": windowID.uuidString.lowercased(),
            "ownerUserId": scope.ownerUserID,
            "mode": mode.rawValue,
            "afterSequence": afterValue,
            "highWaterSequence": highWaterSequence,
            "initialized": initialized,
            "expiresAtMilliseconds": expires,
            "recordCount": recordCount,
            "pageCount": rawPages.count,
            "byteCount": recordsJSON.count,
            "pagesSha256": pagesSHA256
        ]
        let manifestSHA256 = manifestDigest(scope: scope, windowID: windowID, mode: mode, afterSequence: afterSequence,
                                            highWaterSequence: highWaterSequence, initialized: initialized, expires: expires,
                                            recordCount: recordCount, pageCount: rawPages.count, byteCount: recordsJSON.count,
                                            pagesSHA256: pagesSHA256)
        var json = manifestFields
        json["manifestSha256"] = manifestSHA256
        let manifestData = try jsonData(json)
        let manifest = try JSONDecoder().decode(VocabularyWireWindowManifest.self, from: manifestData)
        let pages = try rawPages.enumerated().map { index, bytes in
            try VocabularyWireWindowPage(windowID: windowID, ordinal: index, data: bytes.base64EncodedString(),
                                         sha256: pageDigests[index], byteCount: bytes.count)
        }
        return BuiltWindow(manifest: manifest, manifestData: manifestData, pages: pages, recordsJSON: recordsJSON)
    }

    static func verify(_ built: BuiltWindow, now: Date = Self.now) throws -> VocabularyWireVerifiedWindow {
        var accumulator = try VocabularyWireWindowAccumulator(manifest: built.manifest, expecting: built.manifest.scope, now: now)
        var bytes = Data()
        for page in built.pages { bytes.append(try accumulator.accept(page, now: now)) }
        return try accumulator.finish(recordsJSON: bytes, now: now)
    }

    static func rebuildManifest(
        from data: Data, mutate: (inout [String: Any]) -> Void
    ) throws -> VocabularyWireWindowManifest {
        var object = try jsonObject(data)
        mutate(&object)
        // A changed framing field needs a freshly calculated digest when the goal is to reach
        // accumulator verification. Parse the exact metadata and recompute the Node contract.
        let scope = VocabularyWireWindowScope(
            ownerUserID: try string(object["ownerUserId"]), workspaceID: try uuid(object["workspaceId"]),
            notebookID: try uuid(object["notebookId"]), replicaID: try uuid(object["replicaId"])
        )
        let windowID = try uuid(object["windowId"])
        guard let mode = VocabularyWireWindowManifest.Mode(rawValue: try string(object["mode"])) else {
            throw VocabularyWireWindowError.invalidManifest
        }
        let after = object["afterSequence"] as? String
        let digest = manifestDigest(scope: scope, windowID: windowID, mode: mode, afterSequence: after,
                                    highWaterSequence: try string(object["highWaterSequence"]),
                                    initialized: try bool(object["initialized"]), expires: try integer(object["expiresAtMilliseconds"]),
                                    recordCount: try integer(object["recordCount"]), pageCount: try integer(object["pageCount"]),
                                    byteCount: try integer(object["byteCount"]), pagesSHA256: try string(object["pagesSha256"]))
        object["manifestSha256"] = digest
        return try JSONDecoder().decode(VocabularyWireWindowManifest.self, from: jsonData(object))
    }

    static func manifestDigest(
        scope: VocabularyWireWindowScope, windowID: UUID, mode: VocabularyWireWindowManifest.Mode,
        afterSequence: String?, highWaterSequence: String, initialized: Bool, expires: Int,
        recordCount: Int, pageCount: Int, byteCount: Int, pagesSHA256: String
    ) -> String {
        let owner = Data(scope.ownerUserID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let lines = [
            "lingrove-corpus-window:1", scope.workspaceID.uuidString.lowercased(),
            scope.notebookID.uuidString.lowercased(), scope.replicaID.uuidString.lowercased(),
            windowID.uuidString.lowercased(), owner, mode.rawValue, afterSequence ?? "-", highWaterSequence,
            initialized ? "1" : "0", String(expires), String(recordCount), String(pageCount), String(byteCount), pagesSHA256, ""
        ]
        return sha256(Data(lines.joined(separator: "\n").utf8))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decodeRecords(_ data: Data) throws -> [VocabularyWireCorpusRecord] {
        try JSONDecoder().decode([VocabularyWireCorpusRecord].self, from: data)
    }

    static func decodeRecord(_ object: [String: Any]) throws -> VocabularyWireCorpusRecord {
        try JSONDecoder().decode(VocabularyWireCorpusRecord.self, from: jsonData(object))
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func jsonData(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
    }

    static func dictionary(_ value: Any?) throws -> [String: Any] {
        try #require(value as? [String: Any])
    }

    static func stringDictionary(_ value: Any?) throws -> [String: String] {
        try #require(value as? [String: String])
    }

    static func jsonString(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    static func jsonBool(_ value: Any) throws -> String {
        guard let value = value as? Bool else { throw VocabularyWireWindowError.invalidRecord }
        return value ? "true" : "false"
    }

    static func string(_ value: Any?) throws -> String { try #require(value as? String) }
    static func bool(_ value: Any?) throws -> Bool { try #require(value as? Bool) }
    static func integer(_ value: Any?) throws -> Int { try #require(value as? Int) }
    static func uuid(_ value: Any?) throws -> UUID { try #require(UUID(uuidString: string(value))) }
}

private extension JSONEncoder {
    static func wireEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
