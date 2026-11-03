import LingroveCloud
import SwiftUI

/// Only the outside of the original corpus page is new. This sidebar borrows the window's
/// navigation and the app's safe account/sync projections. Its two footer actions return to
/// SettingsCoordinator, so neither clicking nor reopening it constructs another service graph.
struct NotebookWorkspaceSidebar: View {
    @ObservedObject var navigation: NotebookWorkspaceNavigation
    let account: AccountSessionService?
    let sync: MacNotebookSyncController?
    let openSettings: () -> Void
    let openAccount: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { navigation.destination }, set: navigation.request)) {
                ForEach(NotebookWorkspaceDestination.allCases) { destination in
                    Label(NotebookWorkspaceCopy.title(destination), systemImage: NotebookWorkspaceCopy.symbol(destination))
                        .padding(.vertical, 5)
                        .tag(destination)
                        .accessibilityIdentifier("notebookWorkspace.nav." + destination.rawValue)
                }
            }
            .listStyle(.sidebar)
            .disabled(navigation.hasSheet)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Button(action: openSettings) {
                    Label(String(localized: "Settings"), systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("notebookWorkspace.settings")
                if let account {
                    NotebookWorkspaceAccountButton(account: account, sync: sync, action: openAccount)
                } else {
                    Button(action: openAccount) {
                        Label(String(localized: "Local only", table: "NotebookSync"), systemImage: "person.crop.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("notebookWorkspace.account")
                }
            }
            .buttonStyle(.plain).padding(16)
        }
        .frame(minWidth: 190, maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("notebookWorkspace.sidebar")
    }
}

/// A separate observed fragment keeps account changes local to the footer. A confirmed identity
/// is displayed verbatim; otherwise local use stays explicit. No navigation action grants consent.
private struct NotebookWorkspaceAccountButton: View {
    @ObservedObject var account: AccountSessionService
    let sync: MacNotebookSyncController?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle").imageScale(.large).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.observation.retainedIdentity?.email ?? title)
                        .font(.callout).lineLimit(1).truncationMode(.middle)
                    if let sync, account.observation.retainedIdentity != nil {
                        NotebookWorkspaceSyncStatus(controller: sync)
                    } else {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .help(String(localized: "Account", table: "Account"))
        .accessibilityIdentifier("notebookWorkspace.account")
    }

    private var title: String {
        account.observation.retainedIdentity == nil
            ? NotebookWorkspaceCopy.text("account.localTitle") : AccountPresentation.title(account.state)
    }

    private var detail: String {
        switch account.state {
        case .unconfigured, .signedOut: String(localized: "Local only", table: "NotebookSync")
        default: AccountPresentation.title(account.state)
        }
    }
}

/// Sync remains opt-in and app-owned. A sidebar redraw cannot start work or claim that merely
/// signing in uploaded the corpus; this label displays the controller's actual corpus lane.
private struct NotebookWorkspaceSyncStatus: View {
    @ObservedObject var controller: MacNotebookSyncController
    var body: some View {
        Text(MacNotebookSyncPresentation.title(controller.corpusStatus))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
