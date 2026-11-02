import Foundation

/// Confirmed remote state has its own cursor and tombstones. It is not the local
/// editable document, a pending overlay, or an implicit account/book adoption.
/// The host persists it only in the same transaction as its final local result.
public nonisolated struct VocabularyWireServerShadow: Sendable {
    public let scope: VocabularyWireWindowScope
    public let sequence: VocabularyWireSequence
    public let initialized: Bool
    public let records: [VocabularyWireCorpusRecord]

    public static func empty(scope: VocabularyWireWindowScope) -> Self {
        .init(validatedScope: scope, sequence: .zero, initialized: false, records: [])
    }

    /// Rehydrate durable shadow rows through the same boundary as a new window;
    /// a database flag or cursor alone is never proof of a complete valid graph.
    public init(scope: VocabularyWireWindowScope, sequence: VocabularyWireSequence, initialized: Bool, records: [VocabularyWireCorpusRecord]) throws {
        var ids = Set<String>()
        guard records.allSatisfy({ ids.insert($0.key).inserted && $0.version <= sequence }) else { throw VocabularyWireWindowError.invalidShadow }
        self.init(validatedScope: scope, sequence: sequence, initialized: initialized, records: records)
        try validateGraph()
    }
    private init(validatedScope scope: VocabularyWireWindowScope, sequence: VocabularyWireSequence, initialized: Bool, records: [VocabularyWireCorpusRecord]) {
        self.scope = scope; self.sequence = sequence; self.initialized = initialized
        self.records = records.sorted { $0.key < $1.key }
    }

    public func applying(_ window: VocabularyWireVerifiedWindow, now: Date) throws -> Self {
        let manifest = window.manifest
        try manifest.validate(expecting: scope, now: now)
        guard manifest.highWaterSequence >= sequence else { throw VocabularyWireWindowError.cursorMismatch }
        if manifest.mode == .incremental {
            guard manifest.afterSequence == sequence else { throw VocabularyWireWindowError.cursorMismatch }
        }
        var next = manifest.mode == .bootstrap ? [:] : Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        let prior = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        for record in window.records {
            if let old = prior[record.key] {
                // Canonical identities are retained as tombstones. A bootstrap
                // cannot revive content, roll back a row or rewrite an equal version.
                // A canonical relation restore must cross the deletion boundary
                // in every field/reset clock, including after later patches.
                guard record.version >= old.version,
                      !old.deleted || record.deleted || (VocabularyWireMutationPolicy.canRestore(record.entity.entityType)
                        && record.version > old.version && record.fieldVersions.values.allSatisfy { $0 > old.version }
                        && record.fieldResets.values.allSatisfy { $0 > old.version }),
                      record.version != old.version || record.hasSameWireValue(as: old) else { throw VocabularyWireWindowError.invalidShadow }
                if !old.deleted && !record.deleted {
                    for (field, clock) in old.fieldVersions {
                        guard let nextClock = record.fieldVersions[field], let reset = record.fieldResets[field],
                              nextClock >= clock, reset >= (old.fieldResets[field] ?? .zero) else { throw VocabularyWireWindowError.invalidShadow }
                        if nextClock == clock {
                            guard reset == old.fieldResets[field], let newValue = record.entity.fields[field], let oldValue = old.entity.fields[field],
                                  newValue.hasSameWireValue(as: oldValue) else { throw VocabularyWireWindowError.invalidShadow }
                        }
                    }
                }
            }
            next[record.key] = record
        }
        if manifest.mode == .bootstrap {
            guard Set(prior.keys).isSubset(of: Set(next.keys)) else { throw VocabularyWireWindowError.invalidShadow }
        }
        guard !initialized || manifest.initialized else { throw VocabularyWireWindowError.invalidShadow }
        return try .init(scope: scope, sequence: manifest.highWaterSequence, initialized: manifest.initialized, records: Array(next.values))
    }

    public func materialize(preserving privateState: VocabularyWirePrivateState? = nil) throws -> VocabularyWireMaterialization {
        guard initialized else { throw VocabularyWireWindowError.uninitializedNotebook }
        return try VocabularyWireProjectionCodec.materializeComplete(records.filter { !$0.deleted }.map(\.entity), notebookID: scope.notebookID, preserving: privateState)
    }
    private func validateGraph() throws {
        if initialized {
            _ = try materialize()
        } else if !records.isEmpty { throw VocabularyWireWindowError.invalidShadow }
    }
}
