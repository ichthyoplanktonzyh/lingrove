import Foundation
import LingroveNotebook

/// A conflict names only public identity/field metadata, never source content.
/// The host can present a resolution flow while retaining the old document,
/// shadow and pending journal. No partial candidate is returned on failure.
public nonisolated struct VocabularyWireConflict: Equatable, Sendable {
    public enum Reason: String, Sendable {
        case concurrentCreation, changedDeletion, retiredIdentity, fieldChanged
    }
    public let entityType: VocabularyWireEntityKind
    public let entityID: String
    public let field: String?
    public let reason: Reason
}

public nonisolated enum VocabularyWireRebaseError: Error, Equatable, Sendable {
    case conflicts([VocabularyWireConflict])
    case invalidMergedGraph
}

/// An immutable candidate for the host's CAS-protected local transaction. It
/// carries confirmed remote state separately from the editable document and its
/// private remainder; none of these values acknowledges an upload operation.
public nonisolated struct VocabularyWireRebaseResult: Sendable {
    public let shadow: VocabularyWireServerShadow
    public let materialization: VocabularyWireMaterialization
}

/// Three-way public-field overlay, not another server domain writer. The old
/// confirmed shadow is the ancestor; the local document expresses unacknowledged
/// intent. The verified window supplies the next ancestor. Strict materialization
/// rejects combinations that would leave dangling references or stale evidence.
public nonisolated enum VocabularyWireRebase {
    public static func prepare(
        local: VocabularyDocument, base: VocabularyWireServerShadow,
        window: VocabularyWireVerifiedWindow, retaining privateState: VocabularyWirePrivateState? = nil,
        acknowledging acknowledgement: VocabularyWireUploadAcknowledgement? = nil,
        now: Date
    ) throws -> VocabularyWireRebaseResult {
        let remote = try base.applying(window, now: now)
        if let acknowledgement { try acknowledgement.validateCoverage(base: base, remote: remote) }
        let projection = try VocabularyWireProjectionCodec.project(local, notebookID: base.scope.notebookID, retaining: privateState)
        // An uninitialized server book has no persisted root. Use the empty
        // document only as a logical three-way ancestor, never as proof that a
        // server root exists or as permission to erase a populated local book.
        let empty = try VocabularyWireProjectionCodec.project(VocabularyDocument(), notebookID: base.scope.notebookID).entities
        let before = keyed(acknowledgement?.batch.targetEntities ?? (base.initialized ? base.records.filter { !$0.deleted }.map(\.entity) : empty))
        let incoming = keyed(remote.initialized ? remote.records.filter { !$0.deleted }.map(\.entity) : empty)
        let local = keyed(projection.entities)
        let oldRecords = Dictionary(uniqueKeysWithValues: base.records.map { ($0.key, $0) })
        let newRecords = Dictionary(uniqueKeysWithValues: remote.records.map { ($0.key, $0) })
        let acknowledgedFields = Dictionary(uniqueKeysWithValues: (acknowledgement?.batch.request.members ?? []).map { ($0.change.key, $0.change.writtenFields) })
        let acknowledgedAdditions = Dictionary(uniqueKeysWithValues: (acknowledgement?.batch.request.members ?? []).compactMap { member -> (String, Set<String>)? in
            if case let .patch(_, add) = member.change.action { return (member.change.key, Set(add.keys)) }; return nil
        })
        var merged: [VocabularyWireEntity] = []
        var conflicts: [VocabularyWireConflict] = []
        let keys = Set(before.keys).union(local.keys).union(incoming.keys)
        for key in keys.sorted() {
            let b = before[key], l = local[key], r = incoming[key]
            guard let identity = l ?? r ?? b else { throw VocabularyWireRebaseError.invalidMergedGraph }
            func conflict(_ reason: VocabularyWireConflict.Reason, field: String? = nil) {
                conflicts.append(.init(entityType: identity.entityType, entityID: identity.entityID, field: field, reason: reason))
            }
            if same(l, b) { if let r { merged.append(r) }; continue }
            if l != nil, newRecords[key]?.deleted == true {
                conflict(.retiredIdentity); continue
            }
            if same(l, r) { if let l { merged.append(l) }; continue }
            guard let b else {
                if r == nil, let l { merged.append(l) }
                else { conflict(.concurrentCreation) }
                continue
            }
            guard let l, let r else {
                // Deleting a remotely touched entity needs explicit resolution,
                // even if a later edit happened to restore its earlier content.
                let boundary = acknowledgedFields[key] == nil ? oldRecords[key]?.version : acknowledgement?.receipt.committedSequence
                if l == nil, same(r, b), boundary == newRecords[key]?.version { continue }
                conflict(.changedDeletion); continue
            }
            var fields: [String: VocabularyWireJSON] = [:]
            for field in Set(b.fields.keys).union(l.fields.keys).union(r.fields.keys).sorted() {
                let bv = b.fields[field], lv = l.fields[field], rv = r.fields[field]
                let acknowledgedField = acknowledgedFields[key]?.contains(field) == true
                let boundary = acknowledgedField ? acknowledgement?.receipt.committedSequence : oldRecords[key]?.version
                let touched = boundary.map { (newRecords[key]?.fieldVersions[field] ?? .zero) > $0 } ?? !same(rv, bv)
                if same(lv, bv) { fields[field] = rv }
                else if same(lv, rv) || (!touched && same(rv, bv)) { fields[field] = lv }
                else if field == "updatedAt", case let .number(left)? = lv, case let .number(right)? = rv {
                    fields[field] = .number(max(left, right))
                } else if VocabularyWireMutationPolicy.isAdditive(identity.entityType, field),
                          let boundary, let reset = newRecords[key]?.fieldResets[field], reset <= boundary,
                          let joined = appendOnly(base: bv, local: lv, remote: rv,
                            acknowledgedAdd: acknowledgedAdditions[key]?.contains(field) == true, originalBase: oldRecords[key]?.entity.fields[field]) {
                    fields[field] = joined
                } else { conflict(.fieldChanged, field: field) }
            }
            merged.append(.init(entityType: identity.entityType, entityID: identity.entityID, fields: fields))
        }
        guard conflicts.isEmpty else { throw VocabularyWireRebaseError.conflicts(conflicts) }
        let material: VocabularyWireMaterialization
        do {
            material = try VocabularyWireProjectionCodec.materializeComplete(merged, notebookID: base.scope.notebookID, preserving: projection.privateState)
        } catch { throw VocabularyWireRebaseError.invalidMergedGraph }
        return .init(shadow: remote, materialization: material)
    }

    private static func keyed(_ entities: [VocabularyWireEntity]) -> [String: VocabularyWireEntity] {
        Dictionary(uniqueKeysWithValues: entities.map { ($0.entityType.rawValue + ":" + $0.entityID, $0) })
    }
    private static func same(_ lhs: VocabularyWireEntity?, _ rhs: VocabularyWireEntity?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (l?, r?): l.entityType == r.entityType && l.entityID == r.entityID
            && VocabularyWireJSON.object(l.fields).hasSameWireValue(as: .object(r.fields))
        default: false
        }
    }
    private static func same(_ lhs: VocabularyWireJSON?, _ rhs: VocabularyWireJSON?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (l?, r?): l.hasSameWireValue(as: r)
        default: false
        }
    }
    /// Matches the server's small version-one add-only inventory. Replacement,
    /// removal and reordering stay explicit conflicts; no general array union
    /// can bring back an item another device deliberately removed.
    private static func appendOnly(base: VocabularyWireJSON?, local: VocabularyWireJSON?, remote: VocabularyWireJSON?,
                                   acknowledgedAdd: Bool, originalBase: VocabularyWireJSON?) -> VocabularyWireJSON? {
        guard case let .array(b)? = base, case let .array(l)? = local, case let .array(r)? = remote,
              l.count >= b.count, r.count >= b.count,
              zip(b, l).allSatisfy({ $0.hasSameWireValue(as: $1) }) else { return nil }
        if acknowledgedAdd {
            // A peer may already have appended c when we send [b,c]. The
            // server's deduplication legitimately yields [...,c,b]. Preserve
            // its order, require all sent items and the original confirmed
            // prefix, then append only genuinely new post-send local intent.
            guard case let .array(original)? = originalBase, r.count >= original.count,
                  zip(original, r).allSatisfy({ $0.hasSameWireValue(as: $1) }),
                  b.allSatisfy({ value in r.contains { $0.hasSameWireValue(as: value) } }) else { return nil }
        } else if !zip(b, r).allSatisfy({ $0.hasSameWireValue(as: $1) }) { return nil }
        var result = r
        for value in l.dropFirst(b.count) where !result.contains(where: { $0.hasSameWireValue(as: value) }) { result.append(value) }
        return .array(result)
    }
}
