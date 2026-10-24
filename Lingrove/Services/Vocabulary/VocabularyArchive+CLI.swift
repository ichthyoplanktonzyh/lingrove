import Foundation

/// Automation enters the same archive actor as cards and editors. Reads return portable material
/// without Anki credentials/receipts. A batch's media, content and idempotency receipt share the
/// existing transaction boundary; no CLI code interprets SQL or invokes an AI provider.
extension VocabularyArchive {
    func executeCLI(_ request: CLIRequest) throws -> (CLIJSON, VocabularySnapshot) {
        guard request.version == 1, request.expiresAt > Date() else {
            throw CLIError(code: .timeout, message: "Request expired or protocol version is unsupported.")
        }
        if request.command == .apply {
            return try storageAccess(write: true) { try applyCLI(request) }
        }
        let snapshot = try load()
        let result: CLIJSON
        switch request.command {
        case .status:
            result = .object(["storage": .string("sqlite"), "schemaVersion": .integer(VocabularySQLiteDatabase.schemaVersion),
                "revision": .integer(Int64(snapshot.revision)), "entryCount": .integer(Int64(snapshot.document.entries.count)),
                "senseCount": .integer(Int64(snapshot.document.entries.reduce(0) { $0 + $1.senses.count })),
                "languages": .array(LearningLanguage.allCases.map { .string($0.rawValue) }),
                "kinds": .array(VocabularyEntry.Kind.allCases.map { .string($0.rawValue) })])
        case .list:
            let limit = request.limit ?? 50, offset = request.offset ?? 0
            guard (1...200).contains(limit), offset >= 0, (request.query?.utf8.count ?? 0) <= 4_096,
                  request.language == nil || LearningLanguage(rawValue: request.language ?? "") != nil else {
                throw CLIError.invalid("Use a supported language, a limit of 1–200 and a nonnegative offset.")
            }
            let values = snapshot.document.entries.filter {
                (request.language == nil || $0.language.rawValue == request.language)
                    && VocabularyPolicy.matches($0, query: request.query ?? "")
            }
            let page = values.dropFirst(min(offset, values.count)).prefix(limit).map { entry in
                CLIJSON.object(["entryID": .string(entry.id.uuidString), "expression": .string(Self.cliSummary(entry.expression)),
                    "expressionTruncated": .bool(entry.expression.unicodeScalars.prefix(201).count > 200),
                    "language": .string(entry.language.rawValue), "kind": .string(entry.kind.rawValue),
                    "senseCount": .integer(Int64(entry.senses.count)),
                    "senses": .array(entry.senses.prefix(50).map { .object(["senseID": .string($0.id.uuidString),
                        "meaning": .string(Self.cliSummary($0.meaning)),
                        "meaningTruncated": .bool($0.meaning.unicodeScalars.prefix(201).count > 200),
                        "usageCount": .integer(Int64($0.examples.count))]) })])
            }
            result = .object(["revision": .integer(Int64(snapshot.revision)), "total": .integer(Int64(values.count)),
                "offset": .integer(Int64(offset)), "entries": .array(page)])
        case .get:
            guard let id = request.entryID, let entry = snapshot.document.entries.first(where: { $0.id == id }) else {
                throw CLIError(code: .notFound, message: "Entry not found.")
            }
            try VocabularyCLIReadBudget.validate(entry)
            var options = VocabularyExportConfiguration(); options.explanation = true
            result = .object(["revision": .integer(Int64(snapshot.revision)),
                "entry": try .value(VocabularyExportPolicy.document([entry], configuration: options).entries[0])])
        case .apply: preconditionFailure("Handled before the read path")
        }
        return (result, snapshot)
    }

    private static func cliSummary(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.prefix(200)))
    }

    private func applyCLI(_ request: CLIRequest) throws -> (CLIJSON, VocabularySnapshot) {
        guard let batch = request.batch else { throw CLIError.invalid("The apply command needs a batch.") }
        try CLIInputPolicy.validate(batch)
        let snapshot = try load(), fingerprint = try VocabularyCLIPlan.fingerprint(batch)
        if let receipt = try persistence().receipt(key: batch.idempotencyKey) {
            guard receipt.fingerprint == fingerprint else {
                throw CLIError(code: .conflict, message: "Idempotency key was already used for different content.")
            }
            guard case var .object(result) = try JSONDecoder().decode(CLIJSON.self, from: receipt.result) else {
                throw VocabularyError.invalidArchive
            }
            result["replayed"] = .bool(true)
            result["currentRevision"] = .integer(Int64(snapshot.revision))
            return (.object(result), snapshot)
        }
        guard request.dryRun || snapshot.revision < UInt64(Int64.max) else {
            throw CLIError(code: .conflict, message: "Notebook revision cannot advance.")
        }
        let prepared = try prepareCLIImages(in: batch)
        let plan = try VocabularyCLIPlan(batch: batch, snapshot: snapshot, fingerprint: fingerprint, prepared: prepared, now: Date())
        try validate(plan.document)
        guard request.expiresAt > Date() else { throw CLIError(code: .timeout, message: "Request expired before commit.") }
        let result = CLIJSON.object(["revision": .integer(Int64(snapshot.revision) + (request.dryRun ? 0 : 1)),
            "dryRun": .bool(request.dryRun), "replayed": .bool(false), "operations": .array(plan.outcomes)])
        if request.dryRun { return (result, snapshot) }
        let receipt = VocabularyCLIReceipt(key: batch.idempotencyKey, fingerprint: fingerprint, result: try JSONEncoder().encode(result))
        return (result, try commitWithImages(plan.document, supplied: plan.images, receipt: receipt))
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
