import CryptoKit
import Foundation

/// The app ships an authored, versioned directory rather than importing a tagger's lexicon.
/// The archive loads it once on opening; tests inject small manifests through the same installer.
/// Key-derived IDs let captures refer to stable categories across upgrades and languages.
public nonisolated struct VocabularyClassificationCatalog: Codable, Sendable {
    public struct Category: Codable, Sendable {
        public let key: String
        public let axis: VocabularyCategory.Axis
        public let english: String
        public let chinese: String
        public var definition = ""
        public var examples: [VocabularyCategoryExample]?
        public var scopeNote: String?
        public var references: [VocabularyCategoryReference]?
        public var localizations: [VocabularyCategoryLocalization]?
        public var parents: [String] = []
        public init(key: String, axis: VocabularyCategory.Axis, english: String, chinese: String,
                    definition: String = "", examples: [VocabularyCategoryExample]? = nil,
                    scopeNote: String? = nil, references: [VocabularyCategoryReference]? = nil,
                    localizations: [VocabularyCategoryLocalization]? = nil, parents: [String] = []) {
            self.key = key; self.axis = axis; self.english = english; self.chinese = chinese
            self.definition = definition; self.examples = examples; self.scopeNote = scopeNote
            self.references = references; self.localizations = localizations; self.parents = parents
        }
    }
    public struct Reference: Codable, Sendable {
        public let title: String
        public let url: String
        public let role: String
        public init(title: String, url: String, role: String) { self.title = title; self.url = url; self.role = role }
    }
    public let key: String
    public let version: Int
    public let authorship: String
    public let references: [Reference]
    public var categories: [Category]
    public init(key: String, version: Int, authorship: String, references: [Reference], categories: [Category]) {
        self.key = key; self.version = version; self.authorship = authorship
        self.references = references; self.categories = categories
    }

    public static func bundled(in bundle: Bundle? = nil) throws -> Self {
        guard let url = (bundle ?? .module).url(forResource: "VocabularyClassificationCatalog", withExtension: "json") else {
            throw VocabularyError.invalidArchive
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public static func identifier(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("lingrove.classification\0" + key).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Stage a full replacement in a value before validating. Removed definitions become retired
    /// identities, retaining user children and memberships; local overlays are never rewritten.
    @discardableResult
    public func install(in index: inout VocabularyClassificationIndex, nodes: [VocabularyMeaningNode]) throws -> Bool {
        let frameworkID = Self.identifier(key)
        guard version > 0, !key.isEmpty, Set(categories.map(\.key)).count == categories.count else {
            throw VocabularyError.invalidContent
        }
        if let current = index.frameworks.first(where: { $0.id == frameworkID }) {
            guard current.key == key else { throw VocabularyError.invalidContent }
            if current.version >= version { return false }
        }
        // A known UUID cannot be claimed from a custom/other framework category. Updating
        // only this directory is authorized; unrelated identities remain owned by their source.
        let installedIDs = Set(categories.map { Self.identifier(key + "." + $0.key) })
        guard !index.categories.contains(where: { installedIDs.contains($0.id) && $0.frameworkID != frameworkID }) else {
            throw VocabularyError.invalidContent
        }
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
