import CryptoKit
import Foundation
import LingroveNotebookEngine
import LingroveNotebookSync
import Testing

/// The benchmark owns one closed synthetic book after a real verified-window prepare/commit.
/// An empty, uninitialized remote preserves its local corpus. No transport, credentials or
/// installed state is used. Fresh copies can then differ only in the derived certificate.
@MainActor
enum VocabularyBenchmarkSyncSeed {
    static func prepare(from seed: URL, at directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = directory.appendingPathComponent("primary.sqlite")
        try FileManager.default.copyItem(at: seed, to: database)
        let engine = try LingroveNotebookEngine(databaseURL: database, mediaDirectoryURL: directory.appendingPathComponent("Media"))
        defer { try? engine.close() }
        let version = try #require(try engine.currentNotebookVersion())
        let entries = try engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_entries WHERE workspace_id=?",
            values: [.text(version.workspaceId)])
        let ratings = try engine.loadReviewEventCount()
        let owner = "synthetic-benchmark-owner"
        try engine.updateCloudSettings(cloudState: .linked, linkedUserId: owner, linkedWorkspaceId: version.workspaceId,
            activeWorkspaceId: version.workspaceId, linkedEmail: nil)
        let scope = VocabularyWireWindowScope(ownerUserID: owner, workspaceID: try #require(UUID(uuidString: version.workspaceId)),
            notebookID: version.notebookId, replicaID: UUID())
        let binding = try engine.captureLingroveNotebookWindowBinding(scope: scope)
        let window = try emptyWindow(scope: scope)
        let plan = try engine.prepareLingroveNotebookApply(window, binding: binding, now: Date())
        // Reproduce lost derived metadata immediately before a completely validated writer.
        // The writer, rather than this fixture, must issue its replacement certificate.
        try engine.core.execute(sql: "DELETE FROM notebook_entry_checkpoint", values: [])
        let saved = try engine.commitLingroveNotebookApply(plan, now: Date())
        #expect(saved.workspaceId == version.workspaceId && saved.notebookId == version.notebookId)
        #expect(saved.document.catalog.count == entries && saved.document.interpretations.count == entries * 4)
        #expect(saved.document.semantics.nodes.count == entries * 14 / 10)
        #expect(try engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_entry_checkpoint WHERE workspace_id=?",
            values: [.text(saved.workspaceId)]) == 1)
        #expect(try engine.loadReviewEventCount() == ratings)
        return database
    }

    /// Decode the same public manifest/page contract as a server window. The accumulator
    /// grants the verified-window value only after checking every byte/count/digest and lease.
    private static func emptyWindow(scope: VocabularyWireWindowScope) throws -> VocabularyWireVerifiedWindow {
        let bytes = Data("[]".utf8), windowID = UUID(), now = Date()
        let expires = Int(now.timeIntervalSince1970 * 1_000) + 900_000
        let pagesSHA = digest(Data("0:\(digest(bytes)):\(bytes.count)\n".utf8))
        let owner = Data(scope.ownerUserID.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let lines = ["lingrove-corpus-window:1", scope.workspaceID.uuidString.lowercased(), scope.notebookID.uuidString.lowercased(),
            scope.replicaID.uuidString.lowercased(), windowID.uuidString.lowercased(), owner, "bootstrap", "-", "0", "0",
            String(expires), "0", "1", String(bytes.count), pagesSHA, ""]
        let fields: [String: Any] = ["protocolVersion": 1, "workspaceId": scope.workspaceID.uuidString.lowercased(),
            "notebookId": scope.notebookID.uuidString.lowercased(), "replicaId": scope.replicaID.uuidString.lowercased(),
            "ownerUserId": scope.ownerUserID, "windowId": windowID.uuidString.lowercased(), "mode": "bootstrap",
            "afterSequence": NSNull(), "highWaterSequence": "0", "initialized": false, "expiresAtMilliseconds": expires,
            "recordCount": 0, "pageCount": 1, "byteCount": bytes.count, "pagesSha256": pagesSHA,
            "manifestSha256": digest(Data(lines.joined(separator: "\n").utf8))]
        let manifest = try JSONDecoder().decode(VocabularyWireWindowManifest.self,
            from: JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
        let page = try VocabularyWireWindowPage(windowID: windowID, ordinal: 0, data: bytes.base64EncodedString(),
            sha256: digest(bytes), byteCount: bytes.count)
        var accumulator = try VocabularyWireWindowAccumulator(manifest: manifest, expecting: scope, now: now)
        _ = try accumulator.accept(page, now: now)
        return try accumulator.finish(recordsJSON: bytes, now: now)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
