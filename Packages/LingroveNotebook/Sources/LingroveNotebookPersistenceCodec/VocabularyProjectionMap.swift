/// A row projection keeps an immutable dictionary base plus a bounded value-type overlay.
/// Copying the projection for a transaction therefore copies only recent changes, rather than
/// retaining/releasing every payload in a large Dictionary. Old projections remain immutable;
/// rollback can discard a proposed overlay. Compaction is an amortized in-memory operation,
/// never another storage format, database write or authority boundary.
struct VocabularyProjectionMap<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private var base: [Key: Value]
    private var updates: [Key: Value] = [:]
    private var removed: Set<Key> = []

    init(_ base: [Key: Value] = [:]) { self.base = base }

    subscript(_ key: Key) -> Value? {
        get { removed.contains(key) ? nil : updates[key] ?? base[key] }
        set {
            if let newValue { updates[key] = newValue; removed.remove(key) }
            else {
                updates.removeValue(forKey: key)
                if base[key] != nil { removed.insert(key) }
            }
            compactIfNeeded()
        }
    }

    subscript(_ key: Key, default fallback: @autoclosure () -> Value) -> Value {
        get { self[key] ?? fallback() }
        set { self[key] = newValue }
    }

    mutating func removeValue(forKey key: Key) -> Value? {
        let old = self[key]; self[key] = nil; return old
    }

    var values: [Value] {
        guard !updates.isEmpty || !removed.isEmpty else { return Array(base.values) }
        return Array(materialized().values)
    }

    private func materialized() -> [Key: Value] {
        var result = base
        for key in removed { result.removeValue(forKey: key) }
        for (key, value) in updates { result[key] = value }
        return result
    }

    private mutating func compactIfNeeded() {
        let limit = max(128, min(2_048, base.count / 4))
        guard updates.count + removed.count > limit else { return }
        base = materialized(); updates = [:]; removed = []
    }
}
