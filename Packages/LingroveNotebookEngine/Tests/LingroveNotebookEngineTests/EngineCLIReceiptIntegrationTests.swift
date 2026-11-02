import Foundation
import LingroveNotebook
import LingroveNotebookStorage
import Testing
@testable import LingroveNotebookEngine

/// Real files exercise the host-private ledger together with the existing corpus writer. No
/// test opens a developer directory, starts an account service or reconstructs scheduling state.
@MainActor
struct EngineCLIReceiptIntegrationTests {
    @Test func receiptAndCorpusRollbackTogetherAndReplayAfterJournalAckAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-cli-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sql = root.appendingPathComponent("data.sqlite"), media = root.appendingPathComponent("media")
        var engine = try LingroveNotebookEngine(databaseURL: sql, mediaDirectoryURL: media)
        let workspace = try engine.workspaceSettingsStore.loadWorkspace().workspaceId
        let original = try engine.loadLingroveNotebook(workspaceId: workspace)
        let document = Self.document()
        let invalid = VocabularyCLIReceipt(key: "atomic", fingerprint: String(repeating: "a", count: 64), result: Data("not-json".utf8))
        #expect(throws: VocabularyError.self) { try engine.saveNotebookCLI(document, basedOn: original, images: [:], receipt: invalid) }
        #expect(try engine.loadLingroveNotebook(workspaceId: workspace) == original)
        #expect(try engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_pending_transactions", values: []) == 0)
        #expect(try engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_cli_receipts", values: []) == 0)
        let receipt = VocabularyCLIReceipt(key: "atomic", fingerprint: String(repeating: "a", count: 64), result: Data("{\"revision\":1,\"id\":\"fixed\"}".utf8))
        let saved = try engine.saveNotebookCLI(document, basedOn: original, images: [:], receipt: receipt)
        #expect(saved.snapshot.revision == 1 && !saved.replayed)
        // Journal retirement must not retire a CLI acknowledgement. Sync exact-ACK is covered by
        // the shared engine suites; this probe deliberately removes only that dependent journal.
        _ = try engine.core.inTransaction { try engine.core.execute(sql: "DELETE FROM notebook_pending_transactions", values: []) }
        try engine.close()
        engine = try LingroveNotebookEngine(databaseURL: sql, mediaDirectoryURL: media)
        defer { try? engine.close() }
        let fresh = try engine.loadLingroveNotebook(workspaceId: workspace)
        #expect(try engine.notebookCLIReceipt(key: receipt.key, basedOn: fresh)?.result == receipt.result)
        let replay = try engine.saveNotebookCLI(Self.document(), basedOn: fresh, images: [:], receipt: receipt)
        #expect(replay.replayed && replay.receipt.result == receipt.result && replay.snapshot == fresh)
        #expect(try engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_pending_transactions", values: []) == 0)
        #expect(try engine.core.scalarInt(sql: "SELECT COUNT(*) FROM pragma_foreign_key_check", values: []) == 0)
    }

    @Test func scopeAndCASProtectNewWritesWhileCompletedReplyRemainsReadableInItsBusinessScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-cli-scope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try LingroveNotebookEngine(databaseURL: root.appendingPathComponent("data.sqlite"), mediaDirectoryURL: root.appendingPathComponent("media"))
        defer { try? engine.close() }
        let workspace = try engine.workspaceSettingsStore.loadWorkspace().workspaceId
        let original = try engine.loadLingroveNotebook(workspaceId: workspace)
        let receipt = VocabularyCLIReceipt(key: "scope-key", fingerprint: String(repeating: "b", count: 64), result: Data("{\"ok\":true}".utf8))
        let saved = try engine.saveNotebookCLI(Self.document(), basedOn: original, images: [:], receipt: receipt).snapshot
        #expect(throws: VocabularyError.self) {
            try engine.saveNotebookCLI(Self.document(), basedOn: original, images: [:], receipt: .init(key: "stale", fingerprint: receipt.fingerprint, result: receipt.result))
        }
        let target = UUID().uuidString.lowercased()
        let account = CloudLinkedSession(userId: "synthetic-cli-owner", workspaceId: target, email: nil,
            configurationMode: .custom, apiBaseUrl: "http://127.0.0.1:19380", authorization: .bearer("unused-synthetic"))
        try engine.switchActiveWorkspace(workspace: .init(workspaceId: target, name: "Synthetic", createdAt: "2026-11-03T00:00:00.000Z", isSelected: true), linkedSession: account)
        let different = try engine.loadLingroveNotebook(workspaceId: target)
        #expect(throws: VocabularyError.self) { try engine.notebookCLIReceipt(key: receipt.key, basedOn: different) }
        #expect(throws: VocabularyError.self) { try engine.saveNotebookCLI(Self.document(), basedOn: saved, images: [:], receipt: receipt) }
        try engine.updateCloudSettings(cloudState: .disconnected, linkedUserId: nil, linkedWorkspaceId: nil, activeWorkspaceId: workspace, linkedEmail: nil)
        let returned = try engine.loadLingroveNotebook(workspaceId: workspace)
        #expect(returned.generation != saved.generation)
        #expect(try engine.notebookCLIReceipt(key: receipt.key, basedOn: returned)?.result == receipt.result)
        #expect(throws: VocabularyError.self) { try engine.saveNotebookCLI(Self.document(), basedOn: saved, images: [:], receipt: receipt) }
    }

    @Test func cancelledCLICommandLeavesNeitherContentNorAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-cli-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try LingroveNotebookEngine(databaseURL: root.appendingPathComponent("data.sqlite"), mediaDirectoryURL: root.appendingPathComponent("media"))
        defer { try? engine.close() }
        let workspace = try engine.workspaceSettingsStore.loadWorkspace().workspaceId
        let scope = try engine.loadLingroveNotebook(workspaceId: workspace)
        let rejected = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try engine.saveNotebookCLI(Self.document(), basedOn: scope, images: [:], receipt: .init(key: "cancelled", fingerprint: String(repeating: "c", count: 64), result: Data("{}".utf8)))
                return false
            } catch is CancellationError { return true } catch { Issue.record(error); return false }
        }.value
        #expect(rejected)
        #expect(try engine.loadLingroveNotebook(workspaceId: workspace) == scope)
        #expect(try engine.core.scalarInt(sql: "SELECT COUNT(*) FROM notebook_cli_receipts", values: []) == 0)
    }

    private static func document() -> VocabularyDocument {
        let now = Date()
        let sense = VocabularySense(id: UUID(), meaning: "a happy discovery", isSavedWithoutContext: true, createdAt: now, updatedAt: now)
        return VocabularyDocument(entries: [.init(id: UUID(), expression: "serendipity", dictionaryForm: "serendipity", language: .english,
            kind: .word, senses: [sense], createdAt: now, updatedAt: now)])
    }
}
