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
    var source: LearningDictionarySource { .mdict(id) }
}

nonisolated struct DictionaryWebsite: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var name: String
    var template: String
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

    init(order: [LearningDictionarySource] = LearningDictionarySource.allCases,
         enabled: Set<LearningDictionarySource> = LearningDictionarySource.defaultEnabled,
         libraries: [MDictLibraryDescriptor] = [], websites: [DictionaryWebsite] = [],
         systemFormat: SystemDictionaryFormat = .formatted) {
        self.libraries = libraries
        self.websites = websites
        self.systemFormat = systemFormat
        let sources = LearningDictionarySource.allCases + libraries.map(\.source) + websites.map(\.source)
        let valid = Set(sources)
        var seen = Set<LearningDictionarySource>()
        self.order = (order + sources).filter { valid.contains($0) && seen.insert($0).inserted }
        let enabled = enabled.intersection(valid)
        self.enabled = enabled.isEmpty ? [.bundled] : enabled
    }
    var activeSources: [LearningDictionarySource] { order.filter { enabled.contains($0) } }
    // Website templates never preempt a real definition or open a browser automatically.
    var automaticSources: [LearningDictionarySource] { activeSources.filter { $0.kind != .website } }
    func name(for source: LearningDictionarySource) -> String {
        libraries.first { $0.source == source }?.name ?? websites.first { $0.source == source }?.name ?? source.label
    }
}
