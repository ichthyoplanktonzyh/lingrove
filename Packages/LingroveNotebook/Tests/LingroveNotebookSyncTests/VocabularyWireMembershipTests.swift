import Foundation
import LingroveNotebook
import LingroveNotebookSync
import Testing

/// Existing confirmed ranks are transport history, not new local intent. The same public
/// planner must ignore permutations yet still transmit actual deletions and authored moves.
struct VocabularyWireMembershipTests {
    @Test func legacyRanksAndPermutedMembersProduceNoUploadOrRebaseConflict() throws {
        typealias H = VocabularyWireWindowIntegrationTests
        let scope = H.scope(ownerUserID: "membership@example.test")
        let original = try VocabularyWireTestFixture.document()
        let projection = try VocabularyWireProjectionCodec.project(original, notebookID: scope.notebookID)
        let legacy = projection.entities.enumerated().map { offset, entity in
            var fields = entity.fields
            if fields["rank"] != nil && !entity.entityType.hasBusinessOrder { fields["rank"] = .number(Double(offset + 10)) }
            return VocabularyWireEntity(entityType: entity.entityType, entityID: entity.entityID, fields: fields)
        }
        let rows = try H.rows(from: legacy)
        let records = try rows.map(H.decodeRecord)
        let base = try VocabularyWireServerShadow(scope: scope, sequence: .init("1"), initialized: true, records: records)
        var permuted = original
        permuted.catalog.reverse(); permuted.interpretations.reverse(); permuted.sources.reverse()
        for index in permuted.catalog.indices { permuted.catalog[index].senses.reverse() }
        permuted.semantics.mappings.reverse(); permuted.semantics.patterns.reverse()
        #expect(try VocabularyWireUploadPlanner.make(local: permuted, base: base) == nil)
        let incoming = try legacy.map { try H.row(from: $0, version: "2") }
        let window = try H.verify(H.window(records: incoming, scope: scope, mode: .incremental,
            afterSequence: "1", highWaterSequence: "2", initialized: true), now: Date(timeIntervalSince1970: 1_700_000_000))
        let merged = try VocabularyWireRebase.prepare(local: permuted, base: base, window: window,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(merged.materialization.document == original)

        let entry = try #require(original.entries.first { $0.senses.contains { $0.id == VocabularyWireTestFixture.targetSenseID } })
        var deleted = original
        try VocabularySenseEditingPolicy.remove(entryID: entry.id, senseID: VocabularyWireTestFixture.targetSenseID, from: &deleted)
        let batch = try #require(try VocabularyWireUploadPlanner.make(local: deleted, base: base))
        #expect(!batch.request.members.contains {
            if case let .patch(set, add) = $0.change.action { return Set(set.keys) == ["rank"] && add.isEmpty }
            return false
        })
        #expect(batch.request.members.contains { if case .delete = $0.change.action { true } else { false } })
    }
}
