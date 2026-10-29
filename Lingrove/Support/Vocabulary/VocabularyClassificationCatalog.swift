import CryptoKit
import Foundation

/// The app ships an authored, versioned directory rather than importing a tagger's lexicon.
/// The archive loads it once on opening; tests inject small manifests through the same installer.
/// Key-derived IDs let captures refer to stable categories across upgrades and languages.
nonisolated struct VocabularyClassificationCatalog: Codable, Sendable {
    struct Category: Codable, Sendable {
        let key: String
        let axis: VocabularyCategory.Axis
        let english: String
        let chinese: String
        var definition = ""
        var examples: [VocabularyCategoryExample]?
        var scopeNote: String?
        var references: [VocabularyCategoryReference]?
        var localizations: [VocabularyCategoryLocalization]?
        var parents: [String] = []
    }
    struct Reference: Codable, Sendable {
        let title: String
        let url: String
        let role: String
    }
    let key: String
    let version: Int
    let authorship: String
    let references: [Reference]
    var categories: [Category]

    static func bundled(in bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "VocabularyClassificationCatalog", withExtension: "json") else {
            throw VocabularyError.invalidArchive
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    static func identifier(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("lingrove.classification\0" + key).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Stage a full replacement in a value before validating. Removed definitions become retired
    /// identities, retaining user children and memberships; local overlays are never rewritten.
    @discardableResult
    func install(in index: inout VocabularyClassificationIndex, nodes: [VocabularyMeaningNode]) throws -> Bool {
        let frameworkID = Self.identifier(key)
        guard version > 0, !key.isEmpty, Set(categories.map(\.key)).count == categories.count else {
            throw VocabularyError.invalidContent
        }
        if let current = index.frameworks.first(where: { $0.id == frameworkID }), current.version >= version { return false }
        var next = index
        let framework = VocabularyClassificationFramework(id: frameworkID, key: key, version: version)
        next.frameworks.removeAll { $0.id == frameworkID }; next.frameworks.append(framework)
        let keys = Set(categories.map(\.key)), oldIDs = Set(next.categories.filter { $0.frameworkID == frameworkID }.map(\.id))
        let retired = next.categories.filter { $0.frameworkID == frameworkID && !keys.contains($0.key ?? "") }.map { category in
            var category = category; category.isRetired = true; return category
        }
        next.categories.removeAll { $0.frameworkID == frameworkID }
        next.categories += categories.map { category in
            let seed = key + "." + category.key
            return .init(id: Self.identifier(seed), axis: category.axis,
                labels: [.init(id: Self.identifier(seed + ".en"), text: category.english, language: .english),
                    .init(id: Self.identifier(seed + ".zh"), text: category.chinese, language: .chinese)],
                definition: category.definition, examples: category.examples ?? [], scopeNote: category.scopeNote ?? "",
                references: category.references ?? [],
                localizations: category.localizations ?? [],
                frameworkID: frameworkID, key: category.key,
                provenance: .init(origin: .imported, status: .confirmed, source: "Lingrove classification catalog \(version)"))
        }
        next.categories += retired
        let retiredIDs = Set(retired.map(\.id))
        next.parents.removeAll { oldIDs.contains($0.categoryID) && !retiredIDs.contains($0.categoryID) }
        for category in categories {
            for parent in category.parents {
                guard keys.contains(parent) else { throw VocabularyError.invalidContent }
                let childID = Self.identifier(key + "." + category.key), parentID = Self.identifier(key + "." + parent)
                next.parents.append(.init(id: Self.identifier(key + ".edge." + category.key + "." + parent),
                    categoryID: childID, parentID: parentID))
            }
        }
        try VocabularyClassificationPolicy.validate(next, nodes: nodes)
        index = next
        return true
    }
}
