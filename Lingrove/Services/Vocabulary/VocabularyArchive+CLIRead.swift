import Foundation
import LingroveNotebook
import LingroveNotebookEngine

/// Read projections carry only an owner/version; writes retain the complete committed result
/// needed by UI observers. A partial read cannot accidentally become a complete corpus cache.
nonisolated enum VocabularyCLIExecution: Sendable {
    case read(CLIJSON, LingroveNotebookVersion)
    case complete(CLIJSON, VocabularyArchiveSnapshot)
}

/// Read commands return a fenced projection without installing a complete UI snapshot. The
/// archive owns orchestration and response budgeting; the engine owns all SQL and source joins.
extension VocabularyArchive {
    func boundedCLIRead(_ request: CLIRequest) throws -> VocabularyCLIExecution? {
        let emptyList = request.command == .list && (request.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard emptyList || [.status, .get, .sense, .readMany, .image].contains(request.command) else { return nil }
        return try storageAccess(write: false) {
            let engine = try persistence()
            if try engine.currentNotebookVersion() == nil { _ = try load() }
            let version: LingroveNotebookVersion
            var result: [String: CLIJSON]
            switch request.command {
            case .status:
                let read = try engine.notebookCorpusCounts(); version = read.version
                result = read.counts.mapValues { .integer(Int64($0)) }
                result["storage"] = .string("sqlite")
                result["schemaVersion"] = .integer(Int64(LocalDatabaseSchema.currentVersion))
                result["resources"] = .array(CLIResourceContract.names.map(CLIJSON.string))
                result["languages"] = .array(LearningLanguage.allCases.map { .string($0.rawValue) })
                result["kinds"] = .array(VocabularyEntry.Kind.allCases.map { .string($0.rawValue) })
            case .get, .sense, .readMany:
                (version, result) = try materialCLIRead(request, engine: engine)
            case .list:
                let limit = request.limit ?? 50, offset = request.offset ?? 0
                guard (1...200).contains(limit), offset >= 0, (request.query?.utf8.count ?? 0) <= 4_096,
                      request.language == nil || request.language == "und" ||
                        LearningLanguage(rawValue: request.language ?? "") != nil else {
                    throw CLIError.invalid("Use a supported language, a limit of 1–200 and a nonnegative offset.")
                }
                let page = try engine.readNotebookSummaryPage(language: request.language, limit: limit, offset: offset)
                version = page.fence.version
                result = ["total": .integer(Int64(page.total)), "offset": .integer(Int64(offset)), "entries": .array(page.values),
                    "nextOffset": offset < page.total && page.values.count < page.total - offset
                        ? .integer(Int64(offset + page.values.count)) : .null]
            case .image:
                (version, result) = try imageCLIRead(request, engine: engine)
            default: preconditionFailure("Read admission excludes other commands")
            }
            try validateCLIReadOwner(request, version: version)
            result["revision"] = .integer(Int64(version.revision))
            result["notebookScope"] = try .value(CLINotebookScope(workspaceID: version.workspaceId,
                notebookID: version.notebookId, generation: version.generation))
            let value = CLIJSON.object(result)
            guard try JSONEncoder().encode(value).count <= CLIInputPolicy.maximumBytes - 8_192 else {
                throw CLIError.invalid("Read result is too large. Request fewer records.")
            }
            return .read(value, version)
        }
    }

    private func materialCLIRead(_ request: CLIRequest, engine: LingroveNotebookEngine) throws
        -> (LingroveNotebookVersion, [String: CLIJSON]) {
        let ids: [UUID], senses: Bool, classification: Bool
        if request.command == .readMany {
            guard let selection = request.readSelection else { throw CLIError.invalid("Batch selection is missing.") }
            try selection.validate(); ids = selection.ids
            senses = selection.kind == .senses; classification = selection.includeClassification == true
        } else {
            guard let id = request.command == .get ? request.entryID : request.senseID else {
                throw CLIError.invalid("A record ID is required.")
            }
            ids = [id]; senses = request.command == .sense; classification = false
        }
        let read: NotebookMaterialRead
        do {
            read = try engine.readNotebookMaterial(ids: ids, selectingSenses: senses, includeClassification: classification)
        } catch let error as NotebookToolError {
            if error.code == .notFound { throw CLIError(code: .notFound, message: error.message) }
            throw error
        }
        try VocabularyCLIReadBudget.validate(read.entries)
        var result: [String: CLIJSON]
        if request.command == .readMany {
            result = [senses ? "senses" : "entries": .array(read.values)]
            if classification { result["categoryMemberships"] = .array(read.categoryMemberships) }
        } else { result = [senses ? "sense" : "entry": read.values[0]] }
        return (read.fence.version, result)
    }

    private func imageCLIRead(_ request: CLIRequest, engine: LingroveNotebookEngine) throws
        -> (LingroveNotebookVersion, [String: CLIJSON]) {
        guard request.readScope != nil, let senseID = request.senseID, let digest = request.imageID else {
            throw CLIError(code: .notFound, message: "Image is not present in this sense and notebook scope.")
        }
        let detail = try engine.notebookEntryDetail(senseID: senseID)
        guard let sense = detail.entry?.senses.first(where: { $0.id == senseID }),
              let reference = VocabularyContentPolicy.images(sense.content ?? []).first(where: { $0.digest == digest }) else {
            throw CLIError(code: .notFound, message: "Image is not present in this sense and notebook scope.")
        }
        try validateCLIReadOwner(request, version: detail.fence.version)
        let bytes = try engine.notebookEntryImage(reference, detail: detail)
        return (detail.fence.version, ["senseID": .string(senseID.uuidString), "imageID": .string(digest),
            "mimeType": .string("image/png"), "dataBase64": .string(bytes.base64EncodedString())])
    }

    private func validateCLIReadOwner(_ request: CLIRequest, version: LingroveNotebookVersion) throws {
        try checkCommandOwner(version)
        if let supplied = request.readScope, supplied != CLINotebookScope(workspaceID: version.workspaceId,
            notebookID: version.notebookId, generation: version.generation) { throw VocabularyError.editConflict }
    }
}
