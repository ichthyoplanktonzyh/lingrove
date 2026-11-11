import LingroveNotebook
import Foundation

/// Lossless row conversion is kept outside SQLite and SwiftUI. Each membership and parent edge
/// is independently addressable, so changing one category cannot rewrite expression evidence.
nonisolated enum VocabularyClassificationRows {
    private typealias Row = VocabularyDatabaseRecord

    static func rows(_ index: VocabularyClassificationIndex, appendingTo previous: VocabularyClassificationIndex? = nil) -> [VocabularyDatabaseRecord] {
        var rows: [Row] = []
        for (position, value) in index.frameworks.enumerated().dropFirst(previous?.frameworks.count ?? 0) {
            rows.append(.init(table: .classificationFrameworks, id: value.id.uuidString, parentID: nil,
                position: position, payload: .classificationFramework(value), extra: [value.key]))
        }
        for (position, value) in index.categories.enumerated().dropFirst(previous?.categories.count ?? 0) {
            rows.append(.init(table: .categories, id: value.id.uuidString, parentID: nil, position: position,
                payload: .category(value), extra: [value.frameworkID?.uuidString, value.key, value.axis.rawValue]))
        }
        for (position, value) in index.parents.enumerated().dropFirst(previous?.parents.count ?? 0) {
            rows.append(.init(table: .categoryParents, id: value.id.uuidString, parentID: nil, position: position,
                payload: .categoryParent(value), extra: [value.categoryID.uuidString, value.parentID.uuidString]))
        }
        for (position, value) in index.memberships.enumerated().dropFirst(previous?.memberships.count ?? 0) {
            rows.append(.init(table: .categoryMemberships, id: value.id.uuidString, parentID: nil, position: position,
                payload: .categoryMembership(value), extra: [value.nodeID.uuidString, value.categoryID.uuidString]))
        }
        for (position, value) in index.overrides.enumerated().dropFirst(previous?.overrides.count ?? 0) {
            rows.append(.init(table: .categoryOverrides, id: value.id.uuidString, parentID: value.categoryID.uuidString,
                position: position, payload: .categoryOverride(value)))
        }
        return rows
    }

    static func index(_ rows: VocabularyDatabaseRowIndex) throws -> VocabularyClassificationIndex {
        func records<T>(_ table: Row.Table, value: (Row.Payload) -> T?) throws -> [T] {
            let records = try rows.all(table)
            return try records.map { row in
                guard let value = value(row.payload) else { throw VocabularyError.invalidArchive }; return value
            }
        }
        var index = VocabularyClassificationIndex()
        index.frameworks = try records(.classificationFrameworks) {
            if case let .classificationFramework(value) = $0 { value } else { nil }
        }
        index.categories = try records(.categories) { if case let .category(value) = $0 { value } else { nil } }
        index.parents = try records(.categoryParents) { if case let .categoryParent(value) = $0 { value } else { nil } }
        index.memberships = try records(.categoryMemberships) { if case let .categoryMembership(value) = $0 { value } else { nil } }
        index.overrides = try records(.categoryOverrides) { if case let .categoryOverride(value) = $0 { value } else { nil } }
        return index
    }
}
