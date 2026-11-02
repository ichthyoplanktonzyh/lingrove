import Foundation
import LingroveCloud

/// The process-owned controller borrows this nonsecret preferences adapter. Only deliberate UI
/// choices are saved. Malformed preferences fail closed; corpus, media and review remain in SQL.
@MainActor
final class MacNotebookSyncConsentStore {
    private let defaults: UserDefaults
    private let key = "lingroveNotebookSyncConsentV1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func consent(configuration: AccountServiceConfiguration, identity: AccountIdentity) -> MacNotebookSyncConsent? {
        records().first { $0.matches(configuration, identity: identity) }
    }
    func save(_ consent: MacNotebookSyncConsent) {
        var values = records()
        values.removeAll { $0.endpoint == consent.endpoint && $0.owner == consent.owner }
        values.append(consent)
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }
    private func records() -> [MacNotebookSyncConsent] {
        guard let data = defaults.data(forKey: key), data.count <= 1_048_576,
              let values = try? JSONDecoder().decode([MacNotebookSyncConsent].self, from: data) else { return [] }
        return values.filter { UUID(uuidString: $0.workspaceID) != nil && !$0.owner.isEmpty }
    }
}
