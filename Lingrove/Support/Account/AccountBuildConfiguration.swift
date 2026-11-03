import Foundation
import LingroveCloud

/// A release may bundle a service pair after Lingrove's deployment is ready. The composition
/// root reads Info.plist once and lends this immutable result to the settings store. Both URLs
/// must pass the shared policy together; an absent or broken pair never grants network access.
/// Environment variables deliberately have no role in selecting a production account service.
nonisolated enum AccountBuildConfiguration: Equatable {
    case missing
    case invalid
    case available(AccountServiceConfiguration)

    init(infoDictionary: [String: Any]) {
        let apiValue = infoDictionary["LingroveAccountAPIBaseURL"]
        let authValue = infoDictionary["LingroveAccountAuthBaseURL"]
        let api = (apiValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let auth = (authValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if api.isEmpty, auth.isEmpty, apiValue == nil || apiValue is String, authValue == nil || authValue is String {
            self = .missing
        } else if let configuration = try? AccountConfigurationPolicy.configuration(api: api, auth: auth) {
            self = .available(configuration)
        } else {
            self = .invalid
        }
    }

    var configuration: AccountServiceConfiguration? {
        if case .available(let configuration) = self { return configuration }
        return nil
    }
}
