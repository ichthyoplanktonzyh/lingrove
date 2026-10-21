import Combine
import Foundation

/// LanguageLearningSettings owns this store once. It persists source identities and selected
/// file references; parsing and HTTP remain services. Existing flat order keys stay stable.
@MainActor
final class LearningDictionarySettings: ObservableObject {
    @Published private(set) var configuration: LearningDictionaryConfiguration
    private let defaults: UserDefaults
    private struct Catalog: Codable {
        var libraries: [MDictLibraryDescriptor] = []
        var websites: [DictionaryWebsite] = []
        var systemFormat: SystemDictionaryFormat = .formatted
        var definitionLanguage: LearningLanguage?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let order = defaults.stringArray(forKey: "learningDictionarySourceOrder")?
            .compactMap(LearningDictionarySource.init(rawValue:)) ?? LearningDictionarySource.allCases
        let enabled = defaults.stringArray(forKey: "learningDictionaryEnabledSources")?
            .compactMap(LearningDictionarySource.init(rawValue:)) ?? Array(LearningDictionarySource.defaultEnabled)
        let data = defaults.data(forKey: "learningDictionaryCatalog")
        let catalog = data.flatMap { $0.count <= 2_000_000 ? try? JSONDecoder().decode(Catalog.self, from: $0) : nil } ?? Catalog()
        configuration = .init(order: order, enabled: Set(enabled), libraries: Array(catalog.libraries.prefix(32)),
            websites: Array(catalog.websites.prefix(32)), systemFormat: catalog.systemFormat,
            definitionLanguage: catalog.definitionLanguage)
    }

    func setEnabled(_ enabled: Bool, for source: LearningDictionarySource) {
        guard configuration.order.contains(source) else { return }
        var sources = configuration.enabled
        if enabled { sources.insert(source) } else {
            guard sources.count > 1 else { return }
            sources.remove(source)
        }
        update(replacing(enabled: sources))
    }

    func move(_ source: LearningDictionarySource, by offset: Int) {
        var order = configuration.order
        guard let index = order.firstIndex(of: source), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        update(replacing(order: order))
    }

    @discardableResult func add(_ library: MDictLibraryDescriptor) -> Bool {
        if let old = configuration.libraries.first(where: { $0.id == library.id || $0.mdx.path == library.mdx.path }) {
            let replacement = MDictLibraryDescriptor(id: old.id, name: library.name, mdx: library.mdx,
                resources: library.resources, folder: library.folder, entryCount: library.entryCount,
                languages: library.languages ?? old.languages)
            return update(replacing(libraries: configuration.libraries.map { $0.id == old.id ? replacement : $0 }))
        }
        guard configuration.libraries.count < 32 else { return false }
        return update(replacing(enabled: configuration.enabled.union([library.source]), libraries: configuration.libraries + [library]))
    }

    @discardableResult func add(_ website: DictionaryWebsite) -> Bool {
        if configuration.websites.contains(where: { $0.id == website.id }) { return true }
        guard configuration.websites.count < 32 else { return false }
        // Creating a website does not enable it; its network switch remains an explicit choice.
        return update(replacing(websites: configuration.websites + [website]))
    }

    func remove(_ source: LearningDictionarySource) {
        guard source.kind == .mdict || source.kind == .website else { return }
        update(replacing(order: configuration.order.filter { $0 != source }, enabled: configuration.enabled.subtracting([source]),
            libraries: configuration.libraries.filter { $0.source != source },
            websites: configuration.websites.filter { $0.source != source }))
    }

    @discardableResult func save(_ website: DictionaryWebsite) -> Bool {
        guard !website.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              website.name.utf8.count <= 200,
              DictionaryWebsitePolicy.url(template: website.template, query: "example") != nil else { return false }
        if configuration.websites.contains(where: { $0.id == website.id }) {
            return update(replacing(websites: configuration.websites.map { $0.id == website.id ? website : $0 }))
        } else { return add(website) }
    }

    func setSystemFormat(_ format: SystemDictionaryFormat) { update(replacing(format: format)) }
    func setDefinitionLanguage(_ language: LearningLanguage?) {
        var next = configuration
        next.definitionLanguage = language
        update(next)
    }
    @discardableResult func setLanguages(_ pair: DictionaryLanguagePair, for source: LearningDictionarySource) -> Bool {
        update(replacing(libraries: configuration.libraries.map {
            var book = $0
            if book.source == source { book.languages = pair }
            return book
        }))
    }
    func reset() { update(.init()) }

    private func replacing(order: [LearningDictionarySource]? = nil, enabled: Set<LearningDictionarySource>? = nil,
                           libraries: [MDictLibraryDescriptor]? = nil, websites: [DictionaryWebsite]? = nil,
                           format: SystemDictionaryFormat? = nil) -> LearningDictionaryConfiguration {
        .init(order: order ?? configuration.order, enabled: enabled ?? configuration.enabled,
              libraries: libraries ?? configuration.libraries, websites: websites ?? configuration.websites,
              systemFormat: format ?? configuration.systemFormat, definitionLanguage: configuration.definitionLanguage)
    }

    @discardableResult private func update(_ configuration: LearningDictionaryConfiguration) -> Bool {
        guard configuration != self.configuration else { return true }
        let catalog = Catalog(libraries: configuration.libraries, websites: configuration.websites,
                              systemFormat: configuration.systemFormat, definitionLanguage: configuration.definitionLanguage)
        guard let data = try? JSONEncoder().encode(catalog), data.count <= 2_000_000 else { return false }
        defaults.set(data, forKey: "learningDictionaryCatalog")
        defaults.set(configuration.order.map(\.rawValue), forKey: "learningDictionarySourceOrder")
        defaults.set(configuration.order.filter { configuration.enabled.contains($0) }.map(\.rawValue),
                     forKey: "learningDictionaryEnabledSources")
        self.configuration = configuration
        return true
    }
}
