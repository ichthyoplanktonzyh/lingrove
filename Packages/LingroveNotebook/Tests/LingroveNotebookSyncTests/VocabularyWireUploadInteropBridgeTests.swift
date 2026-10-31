import Foundation
import LingroveNotebook
import LingroveNotebookSync
import Testing

/// Explicit real-Postgres bridge. Only public request/target files leave Swift;
/// private fixture state is rebuilt locally for the final materialization check.
struct VocabularyWireUploadInteropBridgeTests {
    private struct Envelope: Decodable {
        let manifest: VocabularyWireWindowManifest
        let pages: [VocabularyWireWindowPage]
    }
    @Test("nativeUploadInteropBridge", .enabled(if: ProcessInfo.processInfo.environment["LINGROVE_NATIVE_UPLOAD_BRIDGE_PHASE"] != nil))
    func nativeUploadInteropBridge() throws {
        let env = ProcessInfo.processInfo.environment
        func value(_ key: String) throws -> String { try #require(env["LINGROVE_NATIVE_UPLOAD_" + key]) }
        func uuid(_ key: String) throws -> UUID { try #require(UUID(uuidString: value(key))) }
        let scope = try VocabularyWireWindowScope(ownerUserID: value("OWNER"), workspaceID: uuid("WORKSPACE"), notebookID: uuid("BOOK"), replicaID: uuid("REPLICA"))
        let original = try VocabularyWireTestFixture.document()
        let index = try #require(original.collections.firstIndex { $0.senseID == VocabularyWireTestFixture.targetSenseID })
        func verified(_ path: String) throws -> VocabularyWireVerifiedWindow {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            var verifier = try VocabularyWireWindowAccumulator(manifest: envelope.manifest, expecting: scope, now: Date()), bytes = Data()
            for page in envelope.pages { bytes.append(try verifier.accept(page, now: Date())) }
            return try verifier.finish(recordsJSON: bytes, now: Date())
        }
        func write(_ batch: VocabularyWireUploadBatch) throws {
            try batch.encodedBody().write(to: URL(fileURLWithPath: value("REQUEST")))
            try JSONEncoder().encode(batch.targetEntities).write(to: URL(fileURLWithPath: value("TARGET")))
        }
        let phase = try value("BRIDGE_PHASE")
        if phase == "seed" {
            let batch = try #require(try VocabularyWireUploadPlanner.make(local: original, base: .empty(scope: scope)))
            #expect(batch.request.members.count == 41); try write(batch); return
        }
        let base = try VocabularyWireServerShadow.empty(scope: scope).applying(verified(value("BOOTSTRAP")), now: Date())
        #expect(base.sequence.rawValue == "1")
        var sent = original
        sent.collections[index].note = "upload bridge sent"
        sent.collections[index].tags += ["b", "c"]
        sent.catalog[1].updatedAt = original.catalog[1].updatedAt.addingTimeInterval(1)
        if phase == "prepare" {
            let batch = try #require(try VocabularyWireUploadPlanner.make(local: sent, base: base))
            #expect(batch.request.members.count == 1); try write(batch); return
        }
        #expect(phase == "verify")
        let body = try Data(contentsOf: URL(fileURLWithPath: value("REQUEST")))
        let target = try JSONDecoder().decode([VocabularyWireEntity].self, from: Data(contentsOf: URL(fileURLWithPath: value("TARGET"))))
        let batch = try VocabularyWireUploadPlanner.restore(body: body, targetEntities: target, expectedBaseSequence: try .init("1"), base: base)
        let receipt = try JSONDecoder().decode(VocabularyWireGroupReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: value("RECEIPT"))))
        #expect(receipt.committedSequence.rawValue == "3")
        let ack = try VocabularyWireUploadAcknowledgement(batch: batch, receipt: receipt)
        var later = sent
        later.collections[index].note = "upload bridge later"
        later.collections[index].tags.append("later")
        let result = try VocabularyWireRebase.prepare(local: later, base: base,
            window: verified(value("DELTA")), acknowledging: ack, now: Date())
        var expected = later
        expected.collections[index].tags = original.collections[index].tags + ["c", "b", "later"]
        #expect(result.shadow.sequence.rawValue == "3")
        #expect(result.materialization.document == expected)
        #expect(result.materialization.unattachedPrivateState.reviews.isEmpty)
        #expect(result.materialization.unattachedPrivateState.explanations.isEmpty)
    }
}
