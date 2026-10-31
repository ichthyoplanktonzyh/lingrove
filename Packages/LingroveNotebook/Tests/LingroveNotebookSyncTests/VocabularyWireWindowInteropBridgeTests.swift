import Foundation
import Testing
import LingroveNotebookSync

/// Explicitly selected by the real Postgres boundary after building this test
/// bundle. The fixture's private state is rebuilt locally, never exported to Node.
struct VocabularyWireWindowInteropBridgeTests {
    private struct Envelope: Decodable {
        let manifest: VocabularyWireWindowManifest
        let pages: [VocabularyWireWindowPage]
    }
    @Test("nativeWindowInteropBridge", .enabled(if: ProcessInfo.processInfo.environment["LINGROVE_NATIVE_WINDOW_VERIFY"] == "1"))
    func nativeWindowInteropBridge() throws {
        let env = ProcessInfo.processInfo.environment
        func text(_ key: String) throws -> String { try #require(env[key]) }
        func uuid(_ key: String) throws -> UUID { try #require(UUID(uuidString: text(key))) }
        let scope = try VocabularyWireWindowScope(ownerUserID: text("LINGROVE_NATIVE_WINDOW_OWNER"),
            workspaceID: uuid("LINGROVE_NATIVE_WINDOW_WORKSPACE"), notebookID: uuid("LINGROVE_NATIVE_WINDOW_BOOK"), replicaID: uuid("LINGROVE_NATIVE_WINDOW_REPLICA"))
        func envelope(_ key: String) throws -> Envelope {
            try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: URL(fileURLWithPath: text(key))))
        }
        func verify(_ envelope: Envelope) throws -> VocabularyWireVerifiedWindow {
            var verifier = try VocabularyWireWindowAccumulator(manifest: envelope.manifest, expecting: scope, now: Date())
            var bytes = Data()
            for page in envelope.pages { bytes.append(try verifier.accept(page, now: Date())) }
            return try verifier.finish(recordsJSON: bytes, now: Date())
        }
        let original = try VocabularyWireTestFixture.document()
        let privateState = try VocabularyWireProjectionCodec.project(original, notebookID: scope.notebookID).privateState
        let bootstrapEnvelope = try envelope("LINGROVE_NATIVE_WINDOW_BOOTSTRAP")
        let bootstrap = try verify(bootstrapEnvelope)
        #expect(bootstrap.manifest.recordCount == 41)
        #expect(Set(bootstrap.records.map(\.entity.entityType)).count == 29)
        let initial = try VocabularyWireServerShadow.empty(scope: scope).applying(bootstrap, now: Date())
        #expect(initial.sequence.rawValue == "1")
        let initialMaterial = try initial.materialize(preserving: privateState)
        #expect(initialMaterial.document == original)
        #expect(initialMaterial.unattachedPrivateState.reviews.isEmpty)
        #expect(initialMaterial.unattachedPrivateState.explanations.isEmpty)

        let deltaEnvelope = try envelope("LINGROVE_NATIVE_WINDOW_DELTA")
        #expect(deltaEnvelope.manifest.byteCount > 3 * 1024 * 1024)
        #expect(deltaEnvelope.pages.count > 1)
        #expect(deltaEnvelope.pages.dropFirst().contains { page in
            guard let first = Data(base64Encoded: page.data)?.first else { return false }
            return first & 0xC0 == 0x80
        })
        let delta = try verify(deltaEnvelope)
        #expect(delta.records.contains { $0.deleted && $0.entity.entityType == .selectedInterpretation && $0.entity.fields.isEmpty })
        let updated = try initial.applying(delta, now: Date())
        #expect(updated.sequence.rawValue == "4")
        var expected = original
        let collection = try #require(expected.collections.firstIndex { $0.senseID == VocabularyWireTestFixture.targetSenseID })
        expected.collections[collection].note = "From native window DB fixture"
        expected.collections[collection].interpretationIDs = []
        let pattern = try #require(expected.semantics.patterns.firstIndex { $0.senseID == VocabularyWireTestFixture.targetSenseID })
        expected.semantics.patterns[pattern].collocations += (0..<100).map { String(format: "%03d", $0) + String(repeating: "猫", count: 10_900) }
        let material = try updated.materialize(preserving: privateState)
        #expect(material.document == expected)
        #expect(material.unattachedPrivateState.reviews.isEmpty)
        #expect(material.unattachedPrivateState.explanations.isEmpty)
    }
}
