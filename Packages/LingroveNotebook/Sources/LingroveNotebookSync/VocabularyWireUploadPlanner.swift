import Foundation
import LingroveNotebook

/// A public-only frozen target and request. No private state can be encoded as
/// part of the batch; hosts persist target entities separately from exact HTTP
/// bytes and revalidate both against the unchanged confirmed baseline on reopen.
public nonisolated struct VocabularyWireUploadBatch: Sendable {
    public let scope: VocabularyWireWindowScope
    public let baseSequence: VocabularyWireSequence
    public let request: VocabularyWireGroupRequest
    public let targetEntities: [VocabularyWireEntity]
    public func encodedBody() throws -> Data { try request.encodedBody() }
    fileprivate init(scope: VocabularyWireWindowScope, baseSequence: VocabularyWireSequence, request: VocabularyWireGroupRequest, targetEntities: [VocabularyWireEntity]) {
        self.scope = scope; self.baseSequence = baseSequence; self.request = request; self.targetEntities = targetEntities
    }
}

/// Pure diff between confirmed server values and current public intent. It does
/// not dequeue local rows, send HTTP or simulate a canonical server result.
public nonisolated enum VocabularyWireUploadPlanner {
    public static func make(local: VocabularyDocument, base: VocabularyWireServerShadow,
                            initializeEmpty: Bool = false) throws -> VocabularyWireUploadBatch? {
        let target = try VocabularyWireProjectionCodec.project(local, notebookID: base.scope.notebookID).entities
        if !base.initialized && !initializeEmpty && target.count == 1 && local == VocabularyDocument() { return nil }
        let changes = try differences(target: target, base: base)
        guard !changes.isEmpty else { return nil }
        guard changes.count <= 10_000 else { throw VocabularyWireUploadError.requestTooLarge }
        let request = VocabularyWireGroupRequest(notebookID: base.scope.notebookID, groupID: UUID(), replicaID: base.scope.replicaID,
            members: changes.map { .init(memberID: UUID(), change: $0) })
        _ = try request.encodedBody()
        return .init(scope: base.scope, baseSequence: base.sequence, request: request,
            targetEntities: acknowledgedTarget(target, changes: changes, base: base))
    }

    private static func acknowledgedTarget(_ target: [VocabularyWireEntity], changes: [VocabularyWireMutation],
                                            base: VocabularyWireServerShadow) -> [VocabularyWireEntity] {
        let changed = Dictionary(uniqueKeysWithValues: changes.map { ($0.key, $0.writtenFields) })
        let old = Dictionary(uniqueKeysWithValues: base.records.filter { !$0.deleted }.map { ($0.key, $0.entity) })
        return target.map { entity in
            let key = entity.entityType.rawValue + ":" + entity.entityID
            var fields = entity.fields
            // Timestamp-only changes are not an accepted server mutation. Keep
            // their old value in the sent ancestor so a later pull does not
            // mistake this unsent local provenance for acknowledged content.
            if let previous = old[key], fields["updatedAt"] != nil, changed[key]?.contains("updatedAt") != true {
                fields["updatedAt"] = previous.fields["updatedAt"]
            }
            return VocabularyWireEntity(entityType: entity.entityType, entityID: entity.entityID, fields: fields)
        }
    }

    public static func restore(body: Data, targetEntities: [VocabularyWireEntity], expectedBaseSequence: VocabularyWireSequence,
                               base: VocabularyWireServerShadow) throws -> VocabularyWireUploadBatch {
        guard expectedBaseSequence == base.sequence else { throw VocabularyWireUploadError.invalidRequest }
        guard body.count <= 2 * 1024 * 1024 else { throw VocabularyWireUploadError.requestTooLarge }
        let request = try JSONDecoder().decode(VocabularyWireGroupRequest.self, from: body)
        guard request.notebookID == base.scope.notebookID, request.replicaID == base.scope.replicaID else { throw VocabularyWireUploadError.invalidRequest }
        _ = try VocabularyWireProjectionCodec.materializeComplete(targetEntities, notebookID: base.scope.notebookID)
        let expected = try differences(target: targetEntities, base: base)
        guard expected.count == request.members.count,
              zip(expected, request.members).allSatisfy({ $0.json.hasSameWireValue(as: $1.change.json) }),
              zip(targetEntities, acknowledgedTarget(targetEntities, changes: expected, base: base)).allSatisfy({
                  VocabularyWireJSON.object($0.fields).hasSameWireValue(as: .object($1.fields))
              }) else { throw VocabularyWireUploadError.invalidRequest }
        return .init(scope: base.scope, baseSequence: base.sequence, request: request, targetEntities: targetEntities)
    }

    private static func differences(target: [VocabularyWireEntity], base: VocabularyWireServerShadow) throws -> [VocabularyWireMutation] {
        let records = Dictionary(uniqueKeysWithValues: base.records.map { ($0.key, $0) })
        let next = Dictionary(uniqueKeysWithValues: target.map { ($0.entityType.rawValue + ":" + $0.entityID, $0) })
        var result: [VocabularyWireMutation] = []
        for key in Set(records.keys).union(next.keys).sorted() {
            let previous = records[key]
            guard let entity = next[key] else {
                if let previous, !previous.deleted {
                    result.append(.init(entityType: previous.entity.entityType, entityID: previous.entity.entityID,
                        baseVersion: previous.version, action: .delete))
                }
                continue
            }
            if previous?.deleted == true { throw VocabularyWireUploadError.retiredIdentity }
            guard let previous else {
                result.append(.init(entityType: entity.entityType, entityID: entity.entityID, baseVersion: .zero, action: .create(entity.fields)))
                continue
            }
            let old = previous.entity.fields
            guard Set(old.keys) == Set(entity.fields.keys) else { throw VocabularyWireUploadError.invalidTransition }
            let changed = entity.fields.filter { field, value in !value.hasSameWireValue(as: old[field] ?? .null) }
            if changed.isEmpty || changed.keys.allSatisfy({ $0 == "updatedAt" }) { continue }
            if (entity.entityType == .source || entity.entityType == .occurrence) && changed.keys.contains(where: { $0 != "rank" }) {
                throw VocabularyWireUploadError.invalidTransition
            }
            if (entity.entityType == .entry && changed.keys.contains(where: { ["language", "kind"].contains($0) }))
                || (entity.entityType != .meaningNode && changed["createdAt"] != nil)
                || (entity.entityType == .notebookSettings && changed["documentVersion"] != nil) { throw VocabularyWireUploadError.invalidTransition }
            var set: [String: VocabularyWireJSON] = [:], add: [String: VocabularyWireJSON] = [:]
            for (field, value) in changed {
                if VocabularyWireMutationPolicy.isAdditive(entity.entityType, field),
                   case let .array(before)? = old[field], case let .array(after) = value, after.count > before.count,
                   zip(before, after).allSatisfy({ $0.hasSameWireValue(as: $1) }) {
                    add[field] = .array(Array(after.dropFirst(before.count)))
                } else { set[field] = value }
            }
            result.append(.init(entityType: entity.entityType, entityID: entity.entityID, baseVersion: previous.version, action: .patch(set: set, add: add)))
        }
        return result
    }
}

/// A matched receipt plus its immutable sent target. Applying a covering window
/// can then distinguish later local edits from changes already sent by this
/// device; a receipt alone never fabricates field values or advances the shadow.
public nonisolated struct VocabularyWireUploadAcknowledgement: Sendable {
    public let batch: VocabularyWireUploadBatch
    public let receipt: VocabularyWireGroupReceipt
    public init(batch: VocabularyWireUploadBatch, receipt: VocabularyWireGroupReceipt) throws {
        try receipt.validate(for: batch); self.batch = batch; self.receipt = receipt
    }
    func validateCoverage(base: VocabularyWireServerShadow, remote: VocabularyWireServerShadow) throws {
        guard batch.scope == base.scope, batch.baseSequence == base.sequence,
              remote.sequence >= receipt.committedSequence else { throw VocabularyWireUploadError.incompleteReceiptCoverage }
        let records = Dictionary(uniqueKeysWithValues: remote.records.map { ($0.key, $0) })
        let prior = Dictionary(uniqueKeysWithValues: base.records.map { ($0.key, $0) })
        for member in batch.request.members {
            guard let row = records[member.change.key], row.version >= receipt.committedSequence else { throw VocabularyWireUploadError.incompleteReceiptCoverage }
            if case .delete = member.change.action, !row.deleted { throw VocabularyWireUploadError.incompleteReceiptCoverage }
            guard !row.deleted else { continue } // A later deletion remains authoritative.
            let set: [String: VocabularyWireJSON], add: [String: VocabularyWireJSON]
            switch member.change.action {
            case let .create(fields): set = fields; add = [:]
            case let .patch(values, additions): set = values; add = additions
            case .delete: continue
            }
            for (field, value) in set where (row.fieldVersions[field] ?? .zero) <= receipt.committedSequence {
                let actual = row.entity.fields[field]
                if field == "updatedAt", case let .number(desired) = value, case let .number(current)? = actual, current >= desired { continue }
                guard actual.map({ $0.hasSameWireValue(as: value) }) == true else { throw VocabularyWireUploadError.incompleteReceiptCoverage }
            }
            for (field, value) in add where (row.fieldResets[field] ?? .zero) <= receipt.committedSequence {
                guard case let .array(desired) = value, case let .array(current)? = row.entity.fields[field],
                      (row.fieldResets[field] ?? .zero) <= member.change.baseVersion,
                      case let .array(previous)? = prior[member.change.key]?.entity.fields[field], current.count >= previous.count,
                      zip(previous, current).allSatisfy({ $0.hasSameWireValue(as: $1) }),
                      desired.allSatisfy({ item in current.contains { $0.hasSameWireValue(as: item) } }) else { throw VocabularyWireUploadError.incompleteReceiptCoverage }
                // The server deduplicates against the current array. A peer may
                // already have added a later requested item, so request order
                // and duplicate multiplicity are not promises about new items.
            }
        }
    }
}
