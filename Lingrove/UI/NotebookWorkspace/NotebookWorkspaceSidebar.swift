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
            List {
                ForEach(NotebookWorkspaceDestination.allCases) { destination in
                    Button { navigation.request(destination) } label: {
                        Label(NotebookWorkspaceCopy.title(destination), systemImage: NotebookWorkspaceCopy.symbol(destination))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(navigation.destination == destination ? Color.accentColor.opacity(0.15) : Color.clear)
                    .accessibilityAddTraits(navigation.destination == destination ? .isSelected : [])
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
                        Label(String(localized: "Account", table: "Account"), systemImage: "person.crop.circle")
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

/// A separate observed fragment keeps account changes local to the footer. It reads only the
/// existing public state, and deliberately uses the same copy as the original account page.
private struct NotebookWorkspaceAccountButton: View {
    @ObservedObject var account: AccountSessionService
    let sync: MacNotebookSyncController?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle")
                VStack(alignment: .leading, spacing: 4) {
                    Text(AccountPresentation.title(account.state)).font(.callout)
                    if let sync { NotebookWorkspaceSyncStatus(controller: sync) }
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.accessibilityIdentifier("notebookWorkspace.account")
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
