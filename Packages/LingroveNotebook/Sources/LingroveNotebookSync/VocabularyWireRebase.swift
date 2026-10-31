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
        now: Date
    ) throws -> VocabularyWireRebaseResult {
        let remote = try base.applying(window, now: now)
        let projection = try VocabularyWireProjectionCodec.project(local, notebookID: base.scope.notebookID, retaining: privateState)
        // An uninitialized server book has no persisted root. Use the empty
        // document only as a logical three-way ancestor, never as proof that a
        // server root exists or as permission to erase a populated local book.
        let empty = try VocabularyWireProjectionCodec.project(VocabularyDocument(), notebookID: base.scope.notebookID).entities
        let before = keyed(base.initialized ? base.records.filter { !$0.deleted }.map(\.entity) : empty)
        let incoming = keyed(remote.initialized ? remote.records.filter { !$0.deleted }.map(\.entity) : empty)
        let local = keyed(projection.entities)
        let oldRecords = Dictionary(uniqueKeysWithValues: base.records.map { ($0.key, $0) })
        let newRecords = Dictionary(uniqueKeysWithValues: remote.records.map { ($0.key, $0) })
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
                if l == nil, same(r, b), oldRecords[key]?.version == newRecords[key]?.version { continue }
                conflict(.changedDeletion); continue
            }
            var fields: [String: VocabularyWireJSON] = [:]
            for field in Set(b.fields.keys).union(l.fields.keys).union(r.fields.keys).sorted() {
                let bv = b.fields[field], lv = l.fields[field], rv = r.fields[field]
                let touched = oldRecords[key].map { old in
                    (newRecords[key]?.fieldVersions[field] ?? .zero) > old.version
                } ?? !same(rv, bv)
                if same(lv, bv) { fields[field] = rv }
                else if same(lv, rv) || (!touched && same(rv, bv)) { fields[field] = lv }
                else if field == "updatedAt", case let .number(left)? = lv, case let .number(right)? = rv {
                    fields[field] = .number(max(left, right))
                } else if isAdditive(identity.entityType, field),
                          let old = oldRecords[key], let reset = newRecords[key]?.fieldResets[field], reset <= old.version,
                          let joined = appendOnly(base: bv, local: lv, remote: rv) {
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
    private static func isAdditive(_ kind: VocabularyWireEntityKind, _ field: String) -> Bool {
        switch kind {
        case .sense: ["mergedFrom", "standaloneMeanings", "alternateMeanings"].contains(field)
        case .collection: field == "tags"
        case .interpretation: field == "translationVariants"
        case .usagePattern: field == "collocations"
        case .category: ["examples", "references", "localizations"].contains(field)
        default: false
        }
    }
    private static func appendOnly(base: VocabularyWireJSON?, local: VocabularyWireJSON?, remote: VocabularyWireJSON?) -> VocabularyWireJSON? {
        guard case let .array(b)? = base, case let .array(l)? = local, case let .array(r)? = remote,
              l.count >= b.count, r.count >= b.count,
              zip(b, l).allSatisfy({ $0.hasSameWireValue(as: $1) }),
              zip(b, r).allSatisfy({ $0.hasSameWireValue(as: $1) }) else { return nil }
        var result = r
        for value in l.dropFirst(b.count) where !result.contains(where: { $0.hasSameWireValue(as: value) }) { result.append(value) }
        return .array(result)
    }
}
