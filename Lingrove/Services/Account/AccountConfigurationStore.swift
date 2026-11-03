import Foundation
import LingroveCloud

/// Stores only nonsecret connection settings and permission to restore a saved session. The
/// restore bit is cleared *before* logout's Keychain deletion: even a locked/unavailable Keychain
/// cannot revive the old account after relaunch. The app environment owns this store indirectly
/// through its one account service; test suites inject isolated UserDefaults domains. A saved
/// pair always wins over build defaults, including when a later release changes its default.
@MainActor
final class AccountConfigurationStore: AccountConfigurationStoring {
    typealias Record = AccountConnectionRecord

    private let defaults: UserDefaults
    private let key = "lingroveAccountConnectionV1"
    private let disconnectedKey = "lingroveAccountServiceDisconnected"
    private var pendingSelection: (configuration: AccountServiceConfiguration, source: AccountConnectionSource)?
    let buildConfiguration: AccountBuildConfiguration

    init(defaults: UserDefaults = .standard, buildConfiguration: AccountBuildConfiguration = .missing) {
        self.defaults = defaults
        self.buildConfiguration = buildConfiguration
    }

    func load() throws -> Record? {
        guard let data = defaults.data(forKey: key) else {
            guard !defaults.bool(forKey: disconnectedKey), let configuration = buildConfiguration.configuration else { return nil }
            // First launch selects a pair locally, without enabling session restoration or
            // contacting it. Pinning now also prevents an app update from silently changing it.
            persist(configuration, allowsSessionRestore: false, source: .applicationDefault)
            return Record(configuration: configuration, allowsSessionRestore: false)
        }
        guard let record = try? JSONDecoder().decode(StoredAccountConnection.self, from: data),
              let validated = try? AccountConfigurationPolicy.configuration(
                api: record.configuration.apiBaseURL.absoluteString, auth: record.configuration.authBaseURL.absoluteString),
              validated == record.configuration else { throw AccountIssue.invalidConfiguration }
        return Record(configuration: record.configuration, allowsSessionRestore: record.allowsSessionRestore)
    }

    func save(_ configuration: AccountServiceConfiguration, allowsSessionRestore: Bool) {
        // The closed value contains URLs and a boolean only; credential material has no route here.
        let nextSource = pendingSelection.flatMap { $0.configuration == configuration ? $0.source : nil }
        persist(configuration, allowsSessionRestore: allowsSessionRestore, source: nextSource ?? source ?? .custom)
    }

    func clear() {
        // Removing a connection is an explicit choice. A relaunch must not silently reconnect
        // the person to a build default after the session has shown an unconfigured state.
        defaults.set(true, forKey: disconnectedKey)
        defaults.removeObject(forKey: key)
    }

    var source: AccountConnectionSource? {
        if let data = defaults.data(forKey: key) {
            return (try? JSONDecoder().decode(StoredAccountConnection.self, from: data))?.source ?? .custom
        }
        return !defaults.bool(forKey: disconnectedKey) && buildConfiguration.configuration != nil ? .applicationDefault : nil
    }

    /// The facade wraps the shared synchronous switch so its first save of the new pair already
    /// carries the new source. Saves of the old pair retain their source if Keychain deletion
    /// fails. No await can interleave another account operation inside this MainActor scope.
    func selecting(_ source: AccountConnectionSource, for configuration: AccountServiceConfiguration,
                   operation: () -> Bool) -> Bool {
        pendingSelection = (configuration, source)
        defer { pendingSelection = nil }
        guard operation() else { return false }
        // Equal URL pairs are a shared-session no-op, so they need only this source update.
        if self.source != source { selectSource(source) }
        return true
    }

    private func selectSource(_ source: AccountConnectionSource) {
        guard let record = try? load() else { return }
        persist(record.configuration, allowsSessionRestore: record.allowsSessionRestore, source: source)
    }

    private func persist(_ configuration: AccountServiceConfiguration, allowsSessionRestore: Bool,
                         source: AccountConnectionSource) {
        // One encoded value commits URLs, restore permission and source together. Otherwise a
        // crash between separate writes could present a custom service as the app default.
        let record = StoredAccountConnection(configuration: configuration,
            allowsSessionRestore: allowsSessionRestore, source: source)
        defaults.set(try? JSONEncoder().encode(record), forKey: key)
        defaults.set(false, forKey: disconnectedKey)
    }
}

/// This disk snapshot extends the existing nonsecret record with optional source attribution.
/// Previously saved explicit pairs have no source field and remain custom. Each value lives
/// only for a load/save; the store and shared session retain the app's actual state and tokens.
private nonisolated struct StoredAccountConnection: Codable {
    let configuration: AccountServiceConfiguration
    let allowsSessionRestore: Bool
    let source: AccountConnectionSource?
}
