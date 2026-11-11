import Foundation
import LingroveNotebook

/// One decode call owns this temporary address index. Lexical, semantic and directory readers
/// borrow the same typed row array instead of copying every large row into separate grouping
/// dictionaries. Indexes contain integer offsets; the codec retains neither SQL pointers nor
/// another durable representation. Complete reconstruction and row-shape checks share it.
nonisolated struct VocabularyDatabaseRowIndex {
    typealias Row = VocabularyDatabaseRecord
    private struct Owner: Hashable { let table: Row.Table; let parent: String? }
    let rows: [Row]
    private let offsets: [Row.Key: Int]
    private let tables: [Row.Table: [Int]]
    private let owners: [Owner: [Int]]

    init(_ rows: [Row]) throws {
        var offsets: [Row.Key: Int] = [:], tables: [Row.Table: [Int]] = [:], owners: [Owner: [Int]] = [:]
        offsets.reserveCapacity(rows.count)
        for (offset, row) in rows.enumerated() {
            guard offsets.updateValue(offset, forKey: row.key) == nil else { throw VocabularyError.invalidArchive }
            tables[row.table, default: []].append(offset)
            owners[.init(table: row.table, parent: row.parentID), default: []].append(offset)
        }
        self.rows = rows; self.offsets = offsets; self.tables = tables; self.owners = owners
    }

    func offset(for key: Row.Key) -> Int? { offsets[key] }

    func all(_ table: Row.Table) throws -> [Row] {
        try ordered(tables[table] ?? [], table: table)
    }

    func children(_ table: Row.Table, parent: String? = nil) throws -> [Row] {
        try ordered(owners[.init(table: table, parent: parent)] ?? [], table: table)
    }

    private func ordered(_ offsets: [Int], table: Row.Table) throws -> [Row] {
        if !table.hasBusinessOrder {
            return offsets.sorted { rows[$0].id < rows[$1].id }.map { rows[$0] }
        }
        let ordered = offsets.sorted { rows[$0].position < rows[$1].position }
        for (position, offset) in ordered.enumerated() {
            guard rows[offset].position == position else { throw VocabularyError.invalidArchive }
        }
        return ordered.map { rows[$0] }
    }
}
