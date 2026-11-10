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
    func executeCLI(_ request: CLIRequest) throws -> (CLIJSON, VocabularyArchiveSnapshot) {
        guard request.version == CLIServiceIdentity.protocolVersion, request.expiresAt > Date() else {
            throw CLIError(code: .timeout, message: "Request expired or protocol version is unsupported.")
        }
        if request.command == .apply {
            return try storageAccess(write: true) { try applyCLI(request) }
        }
        let snapshot = try load()
        if let supplied = request.readScope {
            guard let scope = snapshot.scope,
                  supplied == CLINotebookScope(workspaceID: scope.workspaceId, notebookID: scope.notebookId,
                    generation: scope.generation) else { throw VocabularyError.editConflict }
        }
        let result: CLIJSON
        switch request.command {
        case .hello: throw CLIError.invalid("Handshake belongs to the CLI transport.")
        case .status:
            result = .object(["storage": .string("sqlite"), "schemaVersion": .integer(Int64(LocalDatabaseSchema.currentVersion)),
                "revision": .integer(Int64(snapshot.revision)), "entryCount": .integer(Int64(snapshot.document.catalog.count)),
                "sourceCount": .integer(Int64(snapshot.document.sources.count)),
                "occurrenceCount": .integer(Int64(snapshot.document.occurrences.count)),
                "interpretationCount": .integer(Int64(snapshot.document.interpretations.count)),
                "resources": .array(CLIResourceContract.names.map(CLIJSON.string)),
                "senseCount": .integer(Int64(snapshot.document.catalog.reduce(0) { $0 + $1.senses.count })),
                "languages": .array(LearningLanguage.allCases.map { .string($0.rawValue) }),
                "kinds": .array(VocabularyEntry.Kind.allCases.map { .string($0.rawValue) })])
        case .list:
            let limit = request.limit ?? 50, offset = request.offset ?? 0
            guard (1...200).contains(limit), offset >= 0, (request.query?.utf8.count ?? 0) <= 4_096,
                  request.language == nil || request.language == "und" || LearningLanguage(rawValue: request.language ?? "") != nil else {
                throw CLIError.invalid("Use a supported language, a limit of 1–200 and a nonnegative offset.")
            }
            let values = snapshot.document.entries.filter {
                (request.language == nil || ($0.language?.rawValue ?? "und") == request.language)
                    && VocabularyPolicy.matches($0, query: request.query ?? "")
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
        case .get:
            guard let id = request.entryID, let entry = snapshot.document.entries.first(where: { $0.id == id }) else {
                throw CLIError(code: .notFound, message: "Entry not found.")
            }
            try VocabularyCLIReadBudget.validate(entry)
            result = .object(["revision": .integer(Int64(snapshot.revision)),
                "entry": try NotebookSenseProjection(snapshot.document).entry(entry)])
        case .sense:
            guard let id = request.senseID,
                  var entry = snapshot.document.entries.first(where: { $0.senses.contains { $0.id == id } }) else {
                throw CLIError(code: .notFound, message: "Sense not found.")
            }
            entry.senses.removeAll { $0.id != id }
            try VocabularyCLIReadBudget.validate(entry)
            result = .object(["revision": .integer(Int64(snapshot.revision)),
                "sense": try NotebookSenseProjection(snapshot.document).sense(id)])
        case .readMany:
            guard let selection = request.readSelection else { throw CLIError.invalid("Batch read selection is missing.") }
            let values = try VocabularyCLIBatchRead.read(selection, from: snapshot.document)
            result = .object(["revision": .integer(Int64(snapshot.revision)), selection.kind.rawValue: .array(values)])
        case .image:
            guard request.readScope != nil, let senseID = request.senseID, let digest = request.imageID,
                  let sense = snapshot.document.catalog.lazy.flatMap(\.senses).first(where: { $0.id == senseID }),
                  let reference = VocabularyContentPolicy.images(sense.content ?? []).first(where: { $0.digest == digest }),
                  let scope = snapshot.scope else {
                throw CLIError(code: .notFound, message: "Image is not present in this sense and notebook scope.")
            }
            let bytes = try LingroveNotebookMediaStore(core: persistence().core)
                .image(reference, scope: scope, requireActiveWorkspace: true)
            result = .object(["revision": .integer(Int64(snapshot.revision)), "senseID": .string(senseID.uuidString),
                "imageID": .string(digest), "mimeType": .string("image/png"), "dataBase64": .string(bytes.base64EncodedString())])
        case .resourceList, .resourceGet: result = try readCLIResources(request, snapshot: snapshot)
        case .apply: preconditionFailure("Handled before the read path")
        }
        guard try JSONEncoder().encode(result).count <= CLIInputPolicy.maximumBytes - 8_192 else {
            throw CLIError.invalid("Read result is too large. Read one sense or a smaller resource page.")
        }
        return (try addingScope(to: result, snapshot: snapshot), snapshot)
    }

    private static func cliSummary(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(200)))
    }

    private func applyCLI(_ request: CLIRequest) throws -> (CLIJSON, VocabularyArchiveSnapshot) {
        guard let batch = request.batch else { throw CLIError.invalid("The apply command needs a batch.") }
        try CLIInputPolicy.validate(batch)
        let snapshot = try load(), fingerprint = try VocabularyCLIPlan.fingerprint(batch)
        guard let scope = snapshot.scope else { throw VocabularyError.editConflict }
        if let receipt = try persistence().notebookCLIReceipt(key: batch.idempotencyKey, basedOn: scope) {
            guard receipt.fingerprint == fingerprint else {
                throw CLIError(code: .conflict, message: "Idempotency key was already used for different content.")
            }
            guard case var .object(result) = try JSONDecoder().decode(CLIJSON.self, from: receipt.result) else {
                throw VocabularyError.invalidArchive
            }
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
        let result = try previewCLI(plan, snapshot: snapshot, dryRun: request.dryRun)
        guard request.expiresAt > Date() else { throw CLIError(code: .timeout, message: "Request expired before commit.") }
        if request.dryRun { return (try addingScope(to: result, snapshot: snapshot), snapshot) }
        let receipt = VocabularyCLIReceipt(key: batch.idempotencyKey, fingerprint: fingerprint, result: try JSONEncoder().encode(result))
        let committed = try commitCLI(plan.document, images: plan.images, receipt: receipt)
        guard case var .object(acknowledgement) = try JSONDecoder().decode(CLIJSON.self, from: committed.receipt.result) else {
            throw VocabularyError.invalidArchive
        }
        acknowledgement["replayed"] = .bool(committed.replayed)
        let saved = VocabularyArchiveSnapshot(committed.snapshot)
        return (try addingScope(to: .object(acknowledgement), snapshot: saved), saved)
    }

    /// Projection assumes a valid graph; callers validate before joining source/node references.
    /// The same bounded value becomes either the dry run or durable acknowledgement, so a write
    /// cannot succeed and then discover that its receipt is too large to return.
    private func previewCLI(_ plan: VocabularyCLIPlan, snapshot: VocabularyArchiveSnapshot, dryRun: Bool) throws -> CLIJSON {
        let changes = try NotebookChangePreview.make(before: snapshot.document, after: plan.document)
        let result = CLIJSON.object(["revision": .integer(Int64(snapshot.revision) + (dryRun ? 0 : 1)),
            "dryRun": .bool(dryRun), "replayed": .bool(false), "operations": .array(plan.outcomes), "changes": changes])
        guard try JSONEncoder().encode(result).count <= 16 * 1_024 * 1_024 else {
            throw CLIError.invalid("Change preview exceeds 16 MiB. Split this material into smaller batches.")
        }
        return result
    }

    private func validateCLIScope(_ batch: CLIBatch, current scope: VocabularyOperationScope) throws {
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
