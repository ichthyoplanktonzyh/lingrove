import Foundation
import LingroveNotebook

/// A conflict names only public identity/field metadata, never source content.
/// The host can present a resolution flow while retaining the old document,
/// shadow and pending journal. No partial candidate is returned on failure.
public nonisolated struct VocabularyWireConflict: Equatable, Codable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case concurrentCreation, changedDeletion, retiredIdentity, fieldChanged, relationshipChanged
    }
    public let entityType: VocabularyWireEntityKind
    public let entityID: String
    public let field: String?
    public let reason: Reason
    public init(entityType: VocabularyWireEntityKind, entityID: String, field: String?, reason: Reason) {
        self.entityType = entityType; self.entityID = entityID; self.field = field; self.reason = reason
    }
}

/// A user's choice is bound to the exact values and server version they saw.
/// Hosts persist these locally; they are never an alternate server write API.
/// A changed value, even one restored to the same text later, requires review.
public nonisolated struct VocabularyWireConflictSelection: Codable, Sendable {
    public enum Choice: String, Codable, Sendable { case local, remote }
    public let conflict: VocabularyWireConflict
    public let local: VocabularyWireEntity?
    public let remote: VocabularyWireEntity?
    public let remoteVersion: VocabularyWireSequence?
    public let choice: Choice

    public init(conflict: VocabularyWireConflict, local: VocabularyWireEntity?, remote: VocabularyWireEntity?,
                remoteVersion: VocabularyWireSequence?, choice: Choice) {
        self.conflict = conflict; self.local = local; self.remote = remote
        self.remoteVersion = remoteVersion; self.choice = choice
    }
}

public nonisolated enum VocabularyWireRebaseError: Error, Equatable, Sendable {
    case conflicts([VocabularyWireConflict])
    case invalidMergedGraph
    case staleResolution
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
        resolving selections: [VocabularyWireConflictSelection] = [],
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
        var consumed = Set<Int>()
        let keys = Set(before.keys).union(local.keys).union(incoming.keys)
        for key in keys.sorted() {
            let b = before[key], l = local[key], r = incoming[key]
            guard let identity = l ?? r ?? b else { throw VocabularyWireRebaseError.invalidMergedGraph }
            func conflict(_ reason: VocabularyWireConflict.Reason, field: String? = nil) throws -> VocabularyWireConflictSelection.Choice? {
                let item = VocabularyWireConflict(entityType: identity.entityType, entityID: identity.entityID, field: field, reason: reason)
                let matches = selections.indices.filter { selections[$0].conflict == item }
                guard matches.count <= 1 else { throw VocabularyWireRebaseError.staleResolution }
                guard let index = matches.first else { conflicts.append(item); return nil }
                let selection = selections[index]
                guard same(selection.local, l), same(selection.remote, r), selection.remoteVersion == newRecords[key]?.version,
                      !(selection.choice == .local && newRecords[key]?.deleted == true) else {
                    throw VocabularyWireRebaseError.staleResolution
                }
                consumed.insert(index)
                return selection.choice
            }
            // Graph conflicts are explicit entity choices, used only after the
            // ordinary field merge proved that relationships cannot coexist.
            if selections.contains(where: { $0.conflict.entityType == identity.entityType && $0.conflict.entityID == identity.entityID && $0.conflict.reason == .relationshipChanged }) {
                let choice = try conflict(.relationshipChanged)
                if let value = choice == .local ? l : r { merged.append(value) }
                continue
            }
            if same(l, b) { if let r { merged.append(r) }; continue }
            if l != nil, newRecords[key]?.deleted == true {
                if try conflict(.retiredIdentity) == .remote, let r { merged.append(r) }; continue
            }
            if same(l, r) { if let l { merged.append(l) }; continue }
            guard let b else {
                if r == nil, let l { merged.append(l) }
                else if let l, let r, sameDirectoryDefinition(l, r) { merged.append(r) }
                else if let choice = try conflict(.concurrentCreation), let value = choice == .local ? l : r { merged.append(value) }
                continue
            }
            guard let l, let r else {
                // Deleting a remotely touched entity needs explicit resolution,
                // even if a later edit happened to restore its earlier content.
                let boundary = acknowledgedFields[key] == nil ? oldRecords[key]?.version : acknowledgement?.receipt.committedSequence
                if l == nil, same(r, b), boundary == newRecords[key]?.version { continue }
                if let choice = try conflict(.changedDeletion), let value = choice == .local ? local[key] : incoming[key] { merged.append(value) }; continue
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
                } else if let choice = try conflict(.fieldChanged, field: field) { fields[field] = choice == .local ? lv : rv }
            }
            merged.append(.init(entityType: identity.entityType, entityID: identity.entityID, fields: fields))
        }
        guard conflicts.isEmpty else { throw VocabularyWireRebaseError.conflicts(conflicts) }
        guard consumed.count == selections.count else { throw VocabularyWireRebaseError.staleResolution }
        let material: VocabularyWireMaterialization
        do {
            material = try VocabularyWireProjectionCodec.materializeComplete(merged, notebookID: base.scope.notebookID, preserving: projection.privateState)
        } catch {
            let related = keys.sorted().compactMap { key -> VocabularyWireConflict? in
                guard !same(local[key], incoming[key]), let entity = local[key] ?? incoming[key] else { return nil }
                return .init(entityType: entity.entityType, entityID: entity.entityID, field: nil, reason: .relationshipChanged)
            }
            guard !related.isEmpty else { throw VocabularyWireRebaseError.invalidMergedGraph }
            throw VocabularyWireRebaseError.conflicts(related)
        }
        return .init(shadow: remote, materialization: material)
    }

    private static func keyed(_ entities: [VocabularyWireEntity]) -> [String: VocabularyWireEntity] {
        Dictionary(uniqueKeysWithValues: entities.map { ($0.entityType.rawValue + ":" + $0.entityID, $0) })
    }
    /// Independent first installations can offset directory ranks around local
    /// custom rows. Equal official definitions share identity; ordering is not
    /// permission to patch or replace a definition from either device.
    private static func sameDirectoryDefinition(_ lhs: VocabularyWireEntity, _ rhs: VocabularyWireEntity) -> Bool {
        guard lhs.entityType == rhs.entityType, lhs.entityID == rhs.entityID,
              [.classificationFramework, .category, .categoryParent].contains(lhs.entityType) else { return false }
        if lhs.entityType == .category, lhs.fields["frameworkId"] == .null { return false }
        return VocabularyWireJSON.object(lhs.fields.filter { $0.key != "rank" }).hasSameWireValue(as:
            .object(rhs.fields.filter { $0.key != "rank" }))
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
