import Foundation
import LingroveNotebook

/// The window's graph presentation owns this single projection worker, separately from the
/// mutable physics worker. Immutable corpus values flow in; one cached rendering snapshot flows
/// out. The key must name the exact saved revision/filter scope passed by the notebook view.
actor VocabularyGraphProjectionWorker {
    struct Projection: Sendable {
        let key: VocabularyGraphProjectionKey
        let identity: UUID
        let snapshot: VocabularyGraphSnapshot
    }
    private var cached: Projection?
    private(set) var buildCount = 0

    func project(key: VocabularyGraphProjectionKey, entries: [VocabularyEntry],
                 semantics: VocabularySemanticIndex?, classification: VocabularyClassificationIndex?) throws -> Projection {
        try Task.checkCancellation()
        if let cached, cached.key == key { return cached }
        let snapshot: VocabularyGraphSnapshot
        if let semantics {
            snapshot = VocabularyGraphProjection.meanings(index: semantics, entries: entries, expanded: key.expanded,
                query: key.query, kind: key.kind, includeEmpty: key.includeEmpty, preferredLanguages: key.languages,
                classification: classification, showsUnexplored: key.showsUnexplored)
        } else {
            snapshot = VocabularyGraphProjection.make(entries: entries, expanded: key.expanded, query: key.query)
        }
        // A replaced filter or hidden destination cannot leave a half-admitted result in the
        // cache. SwiftUI also checks cancellation after the actor hop before presenting it.
        try Task.checkCancellation()
        // A saved note or classification description need not alter visible graph geometry.
        // Compare once on this actor; retain identity so AppKit keeps its accessibility nodes,
        // layout and camera. Literal labels still follow the current authored bytes.
        let sameGraph = cached.map { previous in
            previous.snapshot == snapshot && zip(previous.snapshot.nodes, snapshot.nodes).allSatisfy {
                $0.label.utf8.elementsEqual($1.label.utf8)
            }
        } ?? false
        let result = Projection(key: key, identity: sameGraph ? (cached?.identity ?? UUID()) : UUID(), snapshot: snapshot)
        cached = result; buildCount += 1
        return result
    }
}
