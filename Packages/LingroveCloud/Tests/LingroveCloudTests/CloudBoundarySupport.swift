import CryptoKit
import Foundation
import LingroveCloud
import LingroveNotebook
import LingroveNotebookSync
import Testing

/// Each serialized scenario owns one synthetic Python peer in B's reserved port range. The tests
/// exercise actual URLSession sockets; storage below records real typed protocol stages only.
@MainActor
final class CloudLoopback {
    let process = Process()
    let origin: String
    init() throws {
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [try #require(Bundle.module.url(forResource: "loopback", withExtension: "py", subdirectory: "Fixtures")).path]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let line = String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        guard let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)), (19180...19182).contains(port) else {
            process.terminate(); throw NotebookNetworkError.invalidEndpoint
        }
        origin = "http://127.0.0.1:\(port)"
    }
    func stop() { if process.isRunning { process.terminate(); process.waitUntilExit() } }
    var configuration: AccountServiceConfiguration {
        get throws { try AccountConfigurationPolicy.configuration(api: origin + "/api", auth: origin + "/auth") }
    }
    var account: NotebookAccount {
        .init(userID: "server-owner", workspaceID: CloudFixture.workspace, apiBaseURL: origin + "/api",
            authorizationHeaderValue: "Bearer synthetic-id", isAutomation: true, isTestDistribution: true)
    }
    func mode(_ mode: String) async throws {
        var request = URLRequest(url: try #require(URL(string: origin + "/test/config")))
        request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(["mode": mode])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: request)
    }
    struct Stats: Decodable { let paths: [String]; let refreshes: Int; let leaks: Int }
    func stats() async throws -> Stats {
        let (data, _) = try await URLSession.shared.data(from: try #require(URL(string: origin + "/test/stats")))
        return try JSONDecoder().decode(Stats.self, from: data)
    }
}

enum CloudFixture {
    static let workspace = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let book = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let replica = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    static var image: VocabularyImageReference {
        .init(digest: digest(png), width: 1, height: 1, byteCount: png.count)
    }
    static var scope: VocabularyWireWindowScope {
        .init(ownerUserID: "server-owner", workspaceID: workspace, notebookID: book, replicaID: replica)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func upload(staged: Bool, withImage: Bool = false) throws -> NotebookPendingUpload {
        let base = VocabularyWireServerShadow.empty(scope: scope)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let document: VocabularyDocument
        if withImage {
            let sense = VocabularySense(id: UUID(), meaning: "synthetic meaning", isSavedWithoutContext: true,
                content: [.init(content: .image(image, caption: ""))], createdAt: date, updatedAt: date)
            document = VocabularyDocument(entries: [.init(id: UUID(), expression: "synthetic", dictionaryForm: "synthetic",
                language: .english, kind: .word, senses: [sense], createdAt: date, updatedAt: date)])
        } else { document = VocabularyDocument() }
        let batch = try #require(staged
            ? VocabularyWireUploadPlanner.makeStaged(local: document, base: base, initializeEmpty: true)
            : VocabularyWireUploadPlanner.make(local: document, base: base, initializeEmpty: true))
        let body = try batch.encodedBody()
        return try .init(batch: batch, body: body, outcome: nil, cancelRequested: false,
            frozenSHA256: digest(body), stagedUpload: staged ? .init(batch: batch, frozenBody: body) : nil,
            confirmationManifest: nil, receivedConfirmationOrdinals: [], stagedClosure: nil)
    }
    static func replacing(_ pending: NotebookPendingUpload, outcome: VocabularyWireGroupOutcome? = nil,
                          confirmation: VocabularyWireConfirmationManifest? = nil, pages: [Int] = [],
                          closure: VocabularyWireStagedClosure? = nil, cancelled: Bool = false) throws -> NotebookPendingUpload {
        try .init(batch: pending.batch, body: pending.body, outcome: outcome, cancelRequested: cancelled,
            frozenSHA256: pending.frozenSHA256, stagedUpload: pending.stagedUpload,
            confirmationManifest: confirmation, receivedConfirmationOrdinals: pages, stagedClosure: closure)
    }
}

@MainActor
final class CloudLedger { var events: [String] = [] }

/// Recording repository validates exact outgoing coverage and window/page cryptographic proofs.
/// This intentionally is not a second SQLite engine: durable SQL/rebase/FSRS integration belongs
/// to the host adapter checkpoint. Independent later intent demonstrates exact ACK semantics.
@MainActor
final class RecordingNotebook: NotebookStorage, NotebookReviewStorage, NotebookMediaStorage {
    let ledger: CloudLedger
    var generation = "generation-one"
    var pending: NotebookPendingUpload?
    var localOperations: Set<String> = ["sent"]
    var stateRevision: UInt64 = 1
    var reviewCursor: Int64 = 0
    var reviewOperations: Set<String> = ["00000000-0000-0000-0000-000000000005"]
    var references: [VocabularyImageReference] = []
    var images: [String: Data] = [:]
    var windowPages: [Int: VocabularyWireWindowPage] = [:]
    var confirmationPages: [Int: VocabularyWireConfirmationPage] = [:]
    var readyUploads = false
    var cancelAtControl = false
    var rejectAtNext = false
    init(staged: Bool = false, ledger: CloudLedger = .init()) throws {
        self.ledger = ledger; pending = try CloudFixture.upload(staged: staged)
    }
    func installation(for account: NotebookAccount) throws -> UUID { CloudFixture.replica }
    func capture(scope: VocabularyWireWindowScope) throws -> NotebookBinding { .init(scope: scope, generation: generation) }
    func validate(_ binding: NotebookBinding) throws {
        guard binding.generation == generation, binding.scope.workspaceID == CloudFixture.workspace,
              binding.scope.ownerUserID.utf8.elementsEqual("server-owner".utf8) else { throw NotebookStorageError.bindingChanged }
    }
    func initial(_ binding: NotebookBinding) async throws -> NotebookLocalState { try validate(binding); return metadata }
    func state(_ binding: NotebookBinding) async throws -> NotebookLocalState { try validate(binding); return metadata }
    var metadata: NotebookLocalState { .init(notebookID: CloudFixture.book, revision: stateRevision,
        pendingCount: localOperations.count, uploadCancelled: pending?.cancelRequested ?? false, rejected: false) }
    func ownershipPending(_ binding: NotebookBinding) async throws -> Bool { try validate(binding); return false }
    func sequence(_ binding: NotebookBinding) async throws -> VocabularyWireSequence? { try validate(binding); return .zero }
    func hasConflict(_ binding: NotebookBinding) async throws -> Bool { try validate(binding); return false }
    func next(_ binding: NotebookBinding, staged: VocabularyWireStagedCapabilities?) async throws -> NotebookPendingUpload? {
        try validate(binding); if rejectAtNext { throw NotebookStorageError.rejectedIntent }; return pending
    }
    func control(_ pending: NotebookPendingUpload, binding: NotebookBinding) async throws -> NotebookUploadControl {
        try validate(binding); return .init(cancelRequested: cancelAtControl, hasSettlement: false)
    }
    func existing(_ pending: NotebookPendingUpload, binding: NotebookBinding) async throws -> NotebookPendingUpload {
        try validate(binding); let current = try #require(self.pending)
        #expect(current.frozenSHA256 == pending.frozenSHA256); return current
    }
    func record(_ outcome: VocabularyWireGroupOutcome, pending: NotebookPendingUpload, binding: NotebookBinding) async throws {
        try validate(binding); try outcome.validate(for: pending.batch)
        ledger.events.append("outcome"); self.pending = try CloudFixture.replacing(pending, outcome: outcome)
    }
    func record(_ manifest: VocabularyWireConfirmationManifest, pending: NotebookPendingUpload, binding: NotebookBinding) async throws {
        try validate(binding); try manifest.validate(for: #require(pending.stagedUpload))
        ledger.events.append("confirmation"); self.pending = try CloudFixture.replacing(pending, confirmation: manifest)
    }
    func record(_ page: VocabularyWireConfirmationPage, manifest: VocabularyWireConfirmationManifest,
                pending: NotebookPendingUpload, binding: NotebookBinding) async throws {
        try validate(binding); let upload = try #require(pending.stagedUpload)
        try page.validate(for: manifest, upload: upload); confirmationPages[page.ordinal] = page
        var accumulator = try VocabularyWireConfirmationAccumulator(manifest: manifest, expecting: upload)
        for page in confirmationPages.values.sorted(by: { $0.ordinal < $1.ordinal }) { _ = try accumulator.accept(page) }
        let checked = try accumulator.finish(); ledger.events.append("confirmation-page")
        self.pending = try CloudFixture.replacing(pending, outcome: checked.outcome, confirmation: manifest, pages: [page.ordinal])
    }
    func closeUpload(_ manifest: VocabularyWireStagedManifest, pending: NotebookPendingUpload, binding: NotebookBinding) async throws {
        try validate(binding); let closure = try VocabularyWireStagedClosure(manifest: manifest, upload: #require(pending.stagedUpload))
        ledger.events.append("closure"); self.pending = try CloudFixture.replacing(pending, closure: closure)
    }
    func authorize(_ authorization: NotebookRetryAuthorization) async throws { try validate(authorization.binding); ledger.events.append("authorize") }
    func begin(_ manifest: VocabularyWireWindowManifest, binding: NotebookBinding) async throws -> [Int] {
        try validate(binding); ledger.events.append("begin"); return []
    }
    func receive(_ page: VocabularyWireWindowPage, manifest: VocabularyWireWindowManifest, binding: NotebookBinding) async throws {
        try validate(binding); _ = try page.verifiedBytes(for: manifest, expecting: binding.scope, now: Date())
        ledger.events.append("page"); windowPages[page.ordinal] = page
    }
    func discard(_ manifest: VocabularyWireWindowManifest, binding: NotebookBinding) async throws { try validate(binding); ledger.events.append("discard") }
    func windowReferences(_ manifest: VocabularyWireWindowManifest, images: [String: Data], binding: NotebookBinding) async throws -> [VocabularyImageReference] {
        try validate(binding); return references
    }
    func apply(_ manifest: VocabularyWireWindowManifest, binding: NotebookBinding, images: [String: Data]) async throws {
        try validate(binding)
        var proof = try VocabularyWireWindowAccumulator(manifest: manifest, expecting: binding.scope, now: Date()), bytes = Data()
        for page in windowPages.values.sorted(by: { $0.ordinal < $1.ordinal }) { bytes.append(try proof.accept(page, now: Date())) }
        _ = try proof.finish(recordsJSON: bytes, now: Date())
        ledger.events.append("apply")
        if let outcome = pending?.outcome, case .committed = outcome { localOperations.remove("sent"); pending = nil }
        stateRevision = 2
    }
    func revision(_ binding: NotebookBinding) async throws -> Int64 { try validate(binding); return reviewCursor }
    func request(_ binding: NotebookBinding) async throws -> NotebookReviewRequest {
        try validate(binding)
        // Frozen representative version-one wire data, not another production Card/FSRS codec.
        let body: [String: Any] = ["protocolVersion": 1, "notebookId": CloudFixture.book.uuidString.lowercased(),
            "replicaId": CloudFixture.replica.uuidString.lowercased(), "installationId": CloudFixture.replica.uuidString.lowercased(),
            "afterSequence": reviewCursor, "sourceSequence": "1", "enrollments": [], "links": [], "operations": [],
            "undos": [], "historyAdoptions": [], "confirmations": reviewOperations.sorted().map {
                ["cardId": $0, "linkRevision": 1, "cardOperationId": "00000000-0000-0000-0000-000000000006"] as [String: Any]
            }]
        return try .init(body: JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            afterSequence: reviewCursor, hasWork: !reviewOperations.isEmpty)
    }

    func apply(_ response: Data, request: NotebookReviewRequest, binding: NotebookBinding) async throws -> Bool {
        try validate(binding)
        let reply = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let sent = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let confirmations = try #require(sent["confirmations"] as? [[String: Any]])
        let ack = try #require(reply["confirmed"] as? [String])
        guard Set(ack).isSubset(of: Set(confirmations.compactMap { $0["cardId"] as? String })), reply["notebookId"] as? String == CloudFixture.book.uuidString.lowercased(),
              reply["replicaId"] as? String == CloudFixture.replica.uuidString.lowercased() else { throw NotebookNetworkError.invalidReply }
        ledger.events.append("review-apply"); reviewOperations.subtract(ack); reviewCursor = try #require(reply["afterSequence"] as? Int64)
        return try #require(reply["hasMore"] as? Bool)
    }
    func enqueue(_ references: [VocabularyImageReference], direction: NotebookMediaDirection, consumer: String, binding: NotebookBinding) async throws -> [NotebookMediaJob] {
        try validate(binding); ledger.events.append("pin:" + consumer)
        return references.map { .init(id: $0.digest, reference: $0, direction: direction, state: readyUploads && direction == .upload ? .ready : .queued,
            remoteAssetID: readyUploads && direction == .upload ? CloudFixture.replica : nil, attempts: 0, revision: 1, attemptID: nil) }
    }
    func claim(_ job: NotebookMediaJob, binding: NotebookBinding, recheckReady: Bool) async throws -> NotebookMediaJob {
        try validate(binding); return .init(id: job.id, reference: job.reference, direction: job.direction,
            state: .transferring, remoteAssetID: nil, attempts: 1, revision: 2, attemptID: "attempt")
    }
    func check(_ job: NotebookMediaJob, binding: NotebookBinding) async throws { try validate(binding) }
    func complete(_ job: NotebookMediaJob, assetID: UUID?, received: Data?, binding: NotebookBinding) async throws {
        try validate(binding)
        if let received { guard CloudFixture.digest(received) == job.reference.digest else { throw NotebookMediaError.invalidDescriptor }; images[job.reference.filename] = received }
        ledger.events.append("media-complete")
    }
    func fail(_ job: NotebookMediaJob, state: NotebookMediaState, binding: NotebookBinding) async throws { try validate(binding); ledger.events.append("media-fail") }
    func available(_ job: NotebookMediaJob, binding: NotebookBinding) async throws { try validate(binding) }
    func owned(_ reference: VocabularyImageReference, binding: NotebookBinding) async throws -> Data {
        try validate(binding); guard let data = images[reference.filename] else { throw NotebookMediaError.incomplete(.missing) }; return data
    }
    func release(consumer: String, binding: NotebookBinding) async throws { try validate(binding); ledger.events.append("unpin:" + consumer) }
    func prune(binding: NotebookBinding) async throws -> [VocabularyImageReference] { try validate(binding); return [] }
    func acknowledgeRelease(_ reference: VocabularyImageReference, binding: NotebookBinding) async throws { try validate(binding) }
}

@MainActor
final class RecordingAccountStore: AccountCredentialStoring, AccountConfigurationStoring {
    var record: AccountConnectionRecord?
    var session: AccountStoredSession?
    var writes: [AccountStoredSession] = []
    var failClear = false
    func load() throws -> AccountConnectionRecord? { record }
    func save(_ configuration: AccountServiceConfiguration, allowsSessionRestore: Bool) {
        record = .init(configuration: configuration, allowsSessionRestore: allowsSessionRestore)
    }
    func clear() { record = nil }
    func load(configuration: AccountServiceConfiguration) throws -> AccountStoredSession? { session }
    func save(_ session: AccountStoredSession) throws { self.session = session; writes.append(session) }
    func clear(configuration: AccountServiceConfiguration) throws { if failClear { throw AccountIssue.secureStorage }; session = nil }
}
