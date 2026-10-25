import Foundation

/// A lightweight persistence boundary borrowed by existing settings/download owners. It has no
/// cache, observer or runtime: every read sees the latest shared defaults, including assignments
/// made from another task's manager. Tests inject their own defaults so no user preference leaks.
@MainActor
struct LocalModelTaskAssignments {
    private let defaults: UserDefaults
    private static let key = "lingroveLocalModelTaskAssignments"
    private static let sourcesKey = "lingroveLocalModelSources"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func tasks(for filename: String) -> Set<LocalModelTask> {
        let values = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        return Set((values[filename.lowercased()] ?? []).compactMap(LocalModelTask.init(rawValue:)))
    }

    func recordSource(_ model: DownloadableRuntimeModel) {
        var sources = defaults.dictionary(forKey: Self.sourcesKey) as? [String: String] ?? [:]
        sources[model.filename.lowercased()] = model.downloadURL.absoluteString
        defaults.set(sources, forKey: Self.sourcesKey)
    }

    func source(for filename: String) -> URL? {
        let sources = defaults.dictionary(forKey: Self.sourcesKey) as? [String: String] ?? [:]
        return sources[filename.lowercased()].flatMap(URL.init(string:))
    }

    func clearSource(for filename: String) {
        var sources = defaults.dictionary(forKey: Self.sourcesKey) as? [String: String] ?? [:]
        sources.removeValue(forKey: filename.lowercased())
        defaults.set(sources, forKey: Self.sourcesKey)
    }

    /// Curated entries keep their catalog task. Only an explicit import/download/configuration
    /// grants an unknown file a task; discovering a file in the shared directory never does.
    @discardableResult
    func record(_ filename: String, for task: LocalModelTask) -> Bool {
        if let entry = LocalModelCatalog.descriptor(for: filename) { return entry.task == task }
        if task == .speech, filename.lowercased().contains("mmproj") { return true }
        guard LocalModelTaskPolicy.supports(filename, task: task) else { return false }
        var values = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        var assigned = tasks(for: filename)
        guard assigned.insert(task).inserted else { return true }
        values[filename.lowercased()] = assigned.map(\.rawValue).sorted()
        defaults.set(values, forKey: Self.key)
        return true
    }
}
