import Combine
import Foundation
import LingroveCloud

/// Account has one overview and two secondary settings pages. These values describe only where
/// the window is looking; selecting a page never authenticates, selects a workspace or opts in.
enum AccountSettingsPage: Hashable {
    case service
    case sync
}

/// SettingsNavigationModel retains this child for the window coordinator's lifetime. The account
/// pane observes it directly, so typing a URL does not invalidate the entire Settings split view.
/// Drafts survive leaving a pane, closing Settings and external links back to the overview. The
/// saved service pair remains the sole authority for requests until an explicit confirmed save.
@MainActor
final class AccountSettingsNavigation: ObservableObject {
    @Published var path: [AccountSettingsPage] = []
    @Published var api = ""
    @Published var auth = ""
    private var hasLoaded = false
    private var previousConfiguration: AccountServiceConfiguration?

    func showOverview() { path = [] }

    func show(_ page: AccountSettingsPage) { path = [page] }

    /// A changed service can arrive while the pane is hidden. Refresh a pristine draft, or the
    /// pair just saved by this form, but retain any unrelated edit rather than silently losing it.
    func reconcile(configuration: AccountServiceConfiguration?) {
        let shouldReload = !hasLoaded || !hasChanges(comparedWith: previousConfiguration)
            || matches(configuration)
        previousConfiguration = configuration
        if shouldReload { discardChanges(configuration: configuration) }
    }

    func matches(_ configuration: AccountServiceConfiguration?) -> Bool {
        AccountConfigurationPolicy.matchesSavedConnection(api: api, auth: auth, saved: configuration)
    }

    func hasChanges(comparedWith configuration: AccountServiceConfiguration?) -> Bool {
        if configuration == nil { return !api.isEmpty || !auth.isEmpty }
        return !matches(configuration)
    }

    func discardChanges(configuration: AccountServiceConfiguration?) {
        api = configuration?.apiBaseURL.absoluteString ?? ""
        auth = configuration?.authBaseURL.absoluteString ?? ""
        previousConfiguration = configuration
        hasLoaded = true
    }
}
