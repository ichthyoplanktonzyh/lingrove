import Foundation

/// Stores only nonsecret connection settings and permission to restore a saved session. The
/// restore bit is cleared *before* logout's Keychain deletion: even a locked/unavailable Keychain
/// cannot revive the old account after relaunch. The app environment owns this store indirectly
/// through its one account service; test suites inject isolated UserDefaults domains.
@MainActor
final class AccountConfigurationStore {
    struct Record: Codable, Equatable {
        let configuration: AccountServiceConfiguration
        var allowsSessionRestore: Bool
    }

    private let defaults: UserDefaults
    private let key = "lingroveAccountConnectionV1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> Record? {
        guard let data = defaults.data(forKey: key) else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              let validated = try? AccountConfigurationPolicy.configuration(
                api: record.configuration.apiBaseURL.absoluteString, auth: record.configuration.authBaseURL.absoluteString),
              validated == record.configuration else { throw AccountIssue.invalidConfiguration }
        return record
    }

    func save(_ configuration: AccountServiceConfiguration, allowsSessionRestore: Bool) {
        // The closed value contains URLs and a boolean only; credential material has no route here.
        let record = Record(configuration: configuration, allowsSessionRestore: allowsSessionRestore)
        defaults.set(try? JSONEncoder().encode(record), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
