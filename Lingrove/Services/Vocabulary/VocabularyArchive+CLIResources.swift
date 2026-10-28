import Foundation

extension VocabularyArchive {
    /// Full records give an external agent enough context to maintain explicit links. Paging
    /// and an encoded byte budget bound mailbox output; personal Anki bindings never enter the
    /// resource projection. A read returns the same revision used by later compare-and-swap.
    func readCLIResources(_ request: CLIRequest, snapshot: VocabularySnapshot) throws -> CLIJSON {
        guard let resource = request.resource else { throw CLIError.invalid("A resource name is required.") }
        let records = try VocabularyCLIResources.records(resource, in: snapshot.document)
        if request.command == .resourceGet {
            guard let id = request.resourceID,
                  let record = try records.first(where: { try VocabularyCLIResources.identifier($0, resource: resource) == id }) else {
                throw CLIError(code: .notFound, message: "Resource not found.")
            }
            return .object(["revision": .integer(Int64(snapshot.revision)), "resource": .string(resource), "record": record])
        }
        let limit = request.limit ?? 50, offset = request.offset ?? 0
        guard (1...200).contains(limit), offset >= 0, (request.query?.utf8.count ?? 0) <= 4_096,
              request.claimStatus == nil || (resource == "interpretations" &&
                ["candidate", "accepted", "rejected"].contains(request.claimStatus ?? "")) else {
            throw CLIError.invalid("Use limit 1–200, nonnegative offset, and an interpretation status when applicable.")
        }
        let values = records.filter { record in
            if let id = request.relatedID, !Self.resourceContains(record, uuid: id) { return false }
            if let status = request.claimStatus {
                guard case let .object(fields) = record, fields["status"] == .string(status) else { return false }
            }
            let terms = (request.query ?? "").split(whereSeparator: \.isWhitespace)
            return terms.allSatisfy { Self.resourceContains(record, text: String($0)) }
        }
        let page = Array(values.dropFirst(min(offset, values.count)).prefix(limit))
        let result = CLIJSON.object(["revision": .integer(Int64(snapshot.revision)), "resource": .string(resource),
            "total": .integer(Int64(values.count)), "offset": .integer(Int64(offset)), "records": .array(page),
            "nextOffset": offset < values.count && page.count < values.count - offset ? .integer(Int64(offset + page.count)) : .null])
        guard try JSONEncoder().encode(result).count <= 16 * 1_024 * 1_024 else {
            throw CLIError.invalid("Resource page exceeds 16 MiB. Request a smaller limit.")
        }
        return result
    }

    private static func resourceContains(_ value: CLIJSON, uuid: UUID) -> Bool {
        switch value {
        case let .string(text): UUID(uuidString: text) == uuid
        case let .array(values): values.contains { resourceContains($0, uuid: uuid) }
        case let .object(fields): fields.values.contains { resourceContains($0, uuid: uuid) }
        default: false
        }
    }
    private static func resourceContains(_ value: CLIJSON, text: String) -> Bool {
        switch value {
        case let .string(value): value.localizedStandardContains(text)
        case let .array(values): values.contains { resourceContains($0, text: text) }
        case let .object(fields): fields.values.contains { resourceContains($0, text: text) }
        default: false
        }
    }
}
