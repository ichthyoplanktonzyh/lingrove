import Combine
import Foundation

/// A source identifies a local dictionary adapter, not an inference engine. Sessions can query
/// either source through the same result contract; neither source sends the lookup off the Mac.
nonisolated enum LearningDictionarySource: String, CaseIterable, Codable, Sendable, Identifiable {
    case bundled, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bundled: String(localized: "Built-in expressions", table: "Learning")
        case .system: String(localized: "System Dictionary", table: "Learning")
        }
    }
}

/// One atomic preference value prevents publishing a disabled last source or duplicate order.
/// Lookup tasks capture its enabled order, so a settings edit cannot mutate an in-flight plan.
nonisolated struct LearningDictionaryConfiguration: Equatable, Sendable {
    let order: [LearningDictionarySource]
    let enabled: Set<LearningDictionarySource>

    init(order: [LearningDictionarySource] = LearningDictionarySource.allCases,
         enabled: Set<LearningDictionarySource> = Set(LearningDictionarySource.allCases)) {
        var seen = Set<LearningDictionarySource>()
        self.order = (order + LearningDictionarySource.allCases).filter { seen.insert($0).inserted }
        self.enabled = enabled.isEmpty ? [.bundled] : enabled
    }

    var activeSources: [LearningDictionarySource] { order.filter { enabled.contains($0) } }
}

/// LanguageLearningSettings owns this store once and shares it with both writing/reading cards.
/// Keeping dictionary preferences separate avoids cancelling translation or reloading a model
/// when the user changes a lookup source. Only dictionary sessions subscribe to these changes.
@MainActor
final class LearningDictionarySettings: ObservableObject {
    @Published private(set) var configuration: LearningDictionaryConfiguration
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let order = defaults.stringArray(forKey: "learningDictionarySourceOrder")?
            .compactMap(LearningDictionarySource.init(rawValue:)) ?? LearningDictionarySource.allCases
        let enabled = defaults.stringArray(forKey: "learningDictionaryEnabledSources")?
            .compactMap(LearningDictionarySource.init(rawValue:)) ?? LearningDictionarySource.allCases
        configuration = .init(order: order, enabled: Set(enabled))
    }

    func setEnabled(_ enabled: Bool, for source: LearningDictionarySource) {
        var sources = configuration.enabled
        if enabled { sources.insert(source) } else {
            guard sources.count > 1 else { return }
            sources.remove(source)
        }
        update(.init(order: configuration.order, enabled: sources))
    }

    func move(_ source: LearningDictionarySource, by offset: Int) {
        var order = configuration.order
        guard let index = order.firstIndex(of: source), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        update(.init(order: order, enabled: configuration.enabled))
    }

    func reset() { update(.init()) }

    private func update(_ configuration: LearningDictionaryConfiguration) {
        guard configuration != self.configuration else { return }
        defaults.set(configuration.order.map(\.rawValue), forKey: "learningDictionarySourceOrder")
        defaults.set(configuration.order.filter { configuration.enabled.contains($0) }.map(\.rawValue),
                     forKey: "learningDictionaryEnabledSources")
        self.configuration = configuration
    }
}
