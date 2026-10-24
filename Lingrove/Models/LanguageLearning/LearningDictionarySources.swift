import Foundation

/// Stable identities distinguish a provider from each imported dictionary or website. The
/// original raw values remain readable; optional network sources are never default-on.
nonisolated struct LearningDictionarySource: RawRepresentable, Hashable, Codable, Sendable, Identifiable, CaseIterable {
    enum Kind: Sendable { case bundled, system, mdict, online, website }
    let rawValue: String
    var id: String { rawValue }
    static let bundled = Self(validated: "bundled")
    static let system = Self(validated: "system")
    static let online = Self(validated: "online-english")
    static let allCases: [Self] = [.bundled, .system, .online]
    static let defaultEnabled: Set<Self> = [.bundled, .system]
    private init(validated: String) { rawValue = validated }
    init?(rawValue: String) {
        if ["bundled", "system", "online-english"].contains(rawValue) { self.rawValue = rawValue; return }
        let parts = rawValue.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, ["mdict", "website"].contains(String(parts[0])),
              let id = UUID(uuidString: String(parts[1])) else { return nil }
        self.rawValue = String(parts[0]) + ":" + id.uuidString
    }
    static func mdict(_ id: UUID) -> Self { Self(validated: "mdict:" + id.uuidString) }
    static func website(_ id: UUID) -> Self { Self(validated: "website:" + id.uuidString) }
    var customID: UUID? { rawValue.split(separator: ":", maxSplits: 1).last.flatMap { UUID(uuidString: String($0)) } }
    var kind: Kind {
        if self == .bundled { return .bundled }
        if self == .system { return .system }
        if self == .online { return .online }
        return rawValue.hasPrefix("mdict:") ? .mdict : .website
    }
    var label: String {
        switch kind {
        case .bundled: String(localized: "Built-in expressions", table: "Learning")
        case .system: String(localized: "System Dictionary", table: "Learning")
        case .online: String(localized: "Online English dictionary", table: "Learning")
        case .mdict: String(localized: "MDict dictionary", table: "Learning")
        case .website: String(localized: "Lookup website", table: "Learning")
        }
    }
}

/// Bookmarks refer only to user-selected files and their resource folder. WebKit receives
/// opaque dictionary identities rather than these paths or unrestricted file URLs.
nonisolated struct DictionaryFileReference: Codable, Equatable, Sendable {
    let path: String
    let bookmark: Data
}

nonisolated struct MDictLibraryDescriptor: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    let mdx: DictionaryFileReference
    var resources: [DictionaryFileReference]
    let folder: DictionaryFileReference
    var entryCount: Int
    // An explicit reimport invalidates open-card caches even when file metadata is unchanged.
    var revision: UUID? = UUID()
    var languages: DictionaryLanguagePair?
    var source: LearningDictionarySource { .mdict(id) }
}

nonisolated struct DictionaryWebsite: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var template: String
    var languages: DictionaryLanguagePair?
    var source: LearningDictionarySource { .website(id) }
}

nonisolated enum SystemDictionaryFormat: String, Codable, CaseIterable, Sendable { case formatted, text }

/// One immutable plan includes source configuration, not just visible order. Import/remove/edit
/// invalidates dictionary work and caches without changing translation or inference settings.
nonisolated struct LearningDictionaryConfiguration: Equatable, Sendable {
    let order: [LearningDictionarySource]
    let enabled: Set<LearningDictionarySource>
    var libraries: [MDictLibraryDescriptor]
    var websites: [DictionaryWebsite]
    var systemFormat: SystemDictionaryFormat
    var definitionLanguage: LearningLanguage?

    init(order: [LearningDictionarySource] = LearningDictionarySource.allCases,
         enabled: Set<LearningDictionarySource> = LearningDictionarySource.defaultEnabled,
         libraries: [MDictLibraryDescriptor] = [], websites: [DictionaryWebsite] = [],
         systemFormat: SystemDictionaryFormat = .formatted, definitionLanguage: LearningLanguage? = nil) {
        self.libraries = libraries
        self.websites = websites
        self.systemFormat = systemFormat
        self.definitionLanguage = definitionLanguage
        let sources = LearningDictionarySource.allCases + libraries.map(\.source) + websites.map(\.source)
        let valid = Set(sources)
        var seen = Set<LearningDictionarySource>()
        self.order = (order + sources).filter { valid.contains($0) && seen.insert($0).inserted }
        let enabled = enabled.intersection(valid)
        self.enabled = enabled.isEmpty ? [.bundled] : enabled
    }
    var activeSources: [LearningDictionarySource] { order.filter { enabled.contains($0) } }
    var preferredDefinitionLanguage: LearningLanguage {
        if let definitionLanguage { return definitionLanguage }
        return DictionaryLanguagePair.definitionLanguage(for: Locale.preferredLanguages.first ?? "en")
    }
    func languages(for source: LearningDictionarySource) -> DictionaryLanguagePair? {
        switch source.kind {
        case .bundled: .init(entry: nil, definition: .english, multilingual: true)
        case .online: .init(entry: .english, definition: .english)
        case .system: nil // The helper selects an enabled macOS book using its actual metadata.
        case .mdict: libraries.first { $0.source == source }?.languages
        case .website: websites.first { $0.source == source }?.languages
        }
    }
    func sources(for language: LearningLanguage) -> [LearningDictionarySource] {
        activeSources.filter { languages(for: $0)?.supports(language) ?? true }
    }
    func automaticSources(for language: LearningLanguage) -> [LearningDictionarySource] {
        // Priority remains stable within each gloss tier. A different definition language may
        // be a useful fallback; a different headword language is never a valid fallback.
        let candidates = sources(for: language).filter { source in
            guard source.kind != .website else { return false }
            if source.kind == .mdict {
                // Unknown books stay manually selectable. Guessing their index language from
                // an encoding or a homograph would silently attach the wrong definition.
                let pair = languages(for: source)
                return pair?.entry != nil || pair?.multilingual == true
            }
            return true
        }
        func rank(_ source: LearningDictionarySource) -> Int {
            guard let gloss = languages(for: source)?.definition else { return 1 }
            return gloss == preferredDefinitionLanguage ? 0 : 2
        }
        return candidates.enumerated().sorted {
            let lhs = rank($0.element), rhs = rank($1.element)
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }
    func name(for source: LearningDictionarySource) -> String {
        libraries.first { $0.source == source }?.name ?? websites.first { $0.source == source }?.name ?? source.label
    }
}
