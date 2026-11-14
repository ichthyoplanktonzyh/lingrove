import LingroveNotebookStorage
import LingroveNotebookEngine
import LingroveNotebook
import Foundation

/// Automation enters the same archive actor as cards and editors. Reads return portable material
/// without Anki credentials/receipts. A batch's media, content and idempotency receipt share the
/// existing transaction boundary; no CLI code interprets SQL or invokes an AI provider.
extension VocabularyArchive {
    // One closed command switch keeps scope admission and the common response budget in view.
    // swiftlint:disable:next cyclomatic_complexity
    func executeCLI(_ request: CLIRequest) throws -> VocabularyCLIExecution {
        guard request.version == CLIServiceIdentity.protocolVersion, request.expiresAt > Date() else {
            throw CLIError(code: .timeout, message: "Request expired or protocol version is unsupported.")
        }
        if request.command == .apply {
            let (value, snapshot) = try storageAccess(write: true) { try applyCLI(request) }
            return .complete(value, snapshot)
        }
        if let read = try boundedCLIRead(request) { return read }
        let snapshot = try load()
        if let supplied = request.readScope {
            guard let scope = snapshot.scope,
                  supplied == CLINotebookScope(workspaceID: scope.workspaceId, notebookID: scope.notebookId,
                    generation: scope.generation) else { throw VocabularyError.editConflict }
        }
        let result: CLIJSON
        switch request.command {
        case .hello: throw CLIError.invalid("Handshake belongs to the CLI transport.")
        case .list:
            let limit = request.limit ?? 50, offset = request.offset ?? 0
            guard (1...200).contains(limit), offset >= 0, (request.query?.utf8.count ?? 0) <= 4_096,
                  request.language == nil || request.language == "und" || LearningLanguage(rawValue: request.language ?? "") != nil else {
                throw CLIError.invalid("Use a supported language, a limit of 1–200 and a nonnegative offset.")
            }
            let entries = (snapshot.joinedEntries ?? snapshot.document.entries).filter {
                request.language == nil || ($0.language?.rawValue ?? "und") == request.language
            }
            let values: [VocabularyEntry]
            if (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { values = entries } else {
                cliLiteralIndex.prepare(entries)
                values = cliLiteralIndex.matching(entries, query: request.query ?? "")
            }
            let page = values.dropFirst(min(offset, values.count)).prefix(limit).map { entry in
                CLIJSON.object(["entryID": .string(entry.id.uuidString), "expression": .string(Self.cliSummary(entry.expression)),
                    "expressionTruncated": .bool(entry.expression.unicodeScalars.prefix(201).count > 200),
                    "language": .string(entry.language?.rawValue ?? "und"), "kind": .string(entry.kind.rawValue),
                    "senseCount": .integer(Int64(entry.senses.count)), "sensesTruncated": .bool(entry.senses.count > 50),
                    "senses": .array(entry.senses.prefix(50).map { .object(["senseID": .string($0.id.uuidString),
                        "meaning": .string(Self.cliSummary($0.meaning)),
                        "meaningTruncated": .bool($0.meaning.unicodeScalars.prefix(201).count > 200),
                        "exampleCount": .integer(Int64($0.examples.count))]) })])
            }
            result = .object(["revision": .integer(Int64(snapshot.revision)), "total": .integer(Int64(values.count)),
                "offset": .integer(Int64(offset)), "entries": .array(page),
                "nextOffset": offset < values.count && page.count < values.count - offset ? .integer(Int64(offset + page.count)) : .null])
        case .resourceList, .resourceGet: result = try readCLIResources(request, snapshot: snapshot)
        case .apply, .status, .get, .sense, .readMany, .image: preconditionFailure("Handled before the full read path")
        }
        guard try JSONEncoder().encode(result).count <= CLIInputPolicy.maximumBytes - 8_192 else {
            throw CLIError.invalid("Read result is too large. Read one sense or a smaller resource page.")
        }
        return .complete(try addingScope(to: result, snapshot: snapshot), snapshot)
    }

    private static func cliSummary(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(200)))
    }

    private func applyCLI(_ request: CLIRequest) throws -> (CLIJSON, VocabularyArchiveSnapshot) {
        guard let batch = request.batch else { throw CLIError.invalid("The apply command needs a batch.") }
        try CLIInputPolicy.validate(batch)
        let compactReceipt = request.compactReceipt == true
        guard !compactReceipt || (batch.operations.count == 1 && batch.operations.first?.capture != nil) else {
            throw CLIError.invalid("A compact receipt requires a single capture task.")
        }
        let snapshot = try load(), fingerprint = try VocabularyCLIPlan.fingerprint(batch)
        guard let scope = snapshot.scope else { throw VocabularyError.editConflict }
        if let receipt = try persistence().notebookCLIReceipt(key: batch.idempotencyKey, basedOn: scope) {
            guard receipt.fingerprint == fingerprint else {
                throw CLIError(code: .conflict, message: "Idempotency key was already used for different content.")
            }
            var result = try decodeCLIReceipt(receipt, compact: compactReceipt)
            result["replayed"] = .bool(true)
            result["currentRevision"] = .integer(Int64(snapshot.revision))
            return (try addingScope(to: .object(result), snapshot: snapshot), snapshot)
        }
        try validateCLIScope(batch, current: scope)
        guard request.dryRun || snapshot.revision < UInt64(Int64.max) else {
            throw CLIError(code: .conflict, message: "Notebook revision cannot advance.")
        }
        let prepared = try prepareCLIImages(in: batch)
        let plan = try VocabularyCLIPlan(batch: batch, snapshot: snapshot.portable, fingerprint: fingerprint,
            prepared: prepared, now: Date())
        do { try validate(plan.document) } catch {
            throw CLIError.invalid(
                "Invalid resource relationships or content. Check references, accepted claims and graph constraints.")
        }
        let (result, encoded) = try cliWriteResult(plan, snapshot: snapshot, dryRun: request.dryRun, compactReceipt: compactReceipt)
        guard request.expiresAt > Date() else { throw CLIError(code: .timeout, message: "Request expired before commit.") }
        if request.dryRun { return (try addingScope(to: .object(result), snapshot: snapshot), snapshot) }
        let receipt = VocabularyCLIReceipt(key: batch.idempotencyKey, fingerprint: fingerprint, result: encoded)
        let committed = try commitCLI(plan.document, images: plan.images, receipt: receipt,
            addingNewCaptureEntries: plan.addsOnlyNewCaptureEntries)
        var acknowledgement = committed.replayed ? try decodeCLIReceipt(committed.receipt, compact: compactReceipt) : result
        acknowledgement["replayed"] = .bool(committed.replayed)
        let saved = try committedSnapshot(committed.snapshot)
        return (try addingScope(to: .object(acknowledgement), snapshot: saved), saved)
    }

    private func decodeCLIReceipt(_ receipt: VocabularyCLIReceipt, compact: Bool) throws -> [String: CLIJSON] {
        guard case let .object(result) = try JSONDecoder().decode(CLIJSON.self, from: receipt.result) else {
            throw VocabularyError.invalidArchive
        }
        guard (result["receiptFormat"] == .string("compact")) == compact else {
            throw CLIError(code: .conflict, message: "Retry this key with its original receipt option.")
        }
        return result
    }

    private func cliWriteResult(
        _ plan: VocabularyCLIPlan, snapshot: VocabularyArchiveSnapshot, dryRun: Bool, compactReceipt: Bool
    ) throws -> ([String: CLIJSON], Data) {
        var result: [String: CLIJSON] = ["revision": .integer(Int64(snapshot.revision) + (dryRun ? 0 : 1)),
            "dryRun": .bool(dryRun), "replayed": .bool(false), "operations": .array(plan.outcomes)]
        // A compact commit preserves operation IDs for readback without building before/after projections.
        if dryRun || !compactReceipt {
            result["changes"] = try NotebookChangePreview.make(before: snapshot.document, after: plan.document)
        } else {
            result["receiptFormat"] = .string("compact")
        }
        let encoded = try JSONEncoder().encode(CLIJSON.object(result))
        guard encoded.count <= 16 * 1_024 * 1_024 else {
            let kind = result["changes"] == nil ? "Capture receipt" : "Change preview"
            throw CLIError.invalid(kind + " exceeds 16 MiB. Split this material into smaller batches.")
        }
        return (result, encoded)
    }

    private func validateCLIScope(_ batch: CLIBatch, current scope: LingroveNotebookSnapshot) throws {
        if let supplied = batch.notebookScope {
            guard supplied == CLINotebookScope(workspaceID: scope.workspaceId, notebookID: scope.notebookId,
                generation: scope.generation) else { throw VocabularyError.editConflict }
        } else if batch.expectedRevision != nil || batch.operations.contains(where: {
            $0.append != nil || $0.update != nil || $0.put != nil || $0.delete != nil || $0.merge != nil || $0.remove != nil ||
                $0.capture?.referencesExistingRecords == true || $0.add?.examples?.contains(where: { $0.sourceID != nil }) == true
        }) {
            throw CLIError(code: .conflict,
                message: "Read the notebook again and include its notebookScope when editing existing records.")
        }
    }

    private func addingScope(to value: CLIJSON, snapshot: VocabularyArchiveSnapshot) throws -> CLIJSON {
        guard case var .object(object) = value, let scope = snapshot.scope else { return value }
        object["notebookScope"] = try .value(CLINotebookScope(workspaceID: scope.workspaceId,
            notebookID: scope.notebookId, generation: scope.generation))
        return .object(object)
    }

    /// Media preparation stays inside the archive's storage-access scope and after receipt replay.
    /// A completed retry therefore returns its acknowledgement without decoding or staging images again.
    private func prepareCLIImages(in batch: CLIBatch) throws -> [String: VocabularyPreparedImage] {
        var prepared: [String: VocabularyPreparedImage] = [:]
        for (op, operation) in batch.operations.enumerated() {
            for (block, value) in (operation.add?.content ?? operation.append?.content ?? []).enumerated() {
                if let image = value.image {
                    guard image.path == nil, let data = image.data else {
                        throw CLIError.invalid("Images must be supplied as bytes by the CLI.")
                    }
                    prepared["\(op).\(block)"] = try prepareImage(data)
                }
            }
        }
        return prepared
    }
}
