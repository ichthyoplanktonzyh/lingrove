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
            LingroveSidebarBrandHeader(
                subtitle: NotebookWorkspaceCopy.title(navigation.destination),
                topPadding: 10,
                bottomPadding: 6
            )

            List(selection: Binding(get: { navigation.destination }, set: navigation.request)) {
                Section {
                    ForEach(NotebookWorkspaceDestination.allCases) { destination in
                        let isSelected = navigation.destination == destination
                        Label {
                            Text(NotebookWorkspaceCopy.title(destination))
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        } icon: {
                            Image(systemName: NotebookWorkspaceCopy.symbol(destination))
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(isSelected ? LingroveBrand.accent : .secondary)
                                .frame(width: 20, alignment: .center)
                        }
                        .padding(.vertical, 5)
                        .tag(destination)
                        .accessibilityIdentifier("notebookWorkspace.nav." + destination.rawValue)
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(navigation.hasSheet)

            VStack(alignment: .leading, spacing: 8) {
                if let account {
                    NotebookWorkspaceAccountButton(account: account, sync: sync, action: openAccount)
                } else {
                    Button(action: openAccount) {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(LingroveBrand.accent.opacity(0.11))
                                    .frame(width: 28, height: 28)
                                LingroveWhaleGlyph(size: 14, tint: LingroveBrand.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(NotebookWorkspaceCopy.text("account.localTitle"))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(String(localized: "Local only", table: "NotebookSync"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("notebookWorkspace.account")
                }

                Button(action: openSettings) {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .center)
                        Text(String(localized: "Settings"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.025))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("notebookWorkspace.settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .overlay(alignment: .top) {
                Divider().opacity(0.6)
            }
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

    private var hasIdentity: Bool { account.observation.retainedIdentity != nil }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(hasIdentity ? LingroveBrand.accent.opacity(0.14) : LingroveBrand.accent.opacity(0.11))
                        .frame(width: 28, height: 28)
                    if hasIdentity {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(LingroveBrand.accent)
                    } else {
                        LingroveWhaleGlyph(size: 14, tint: LingroveBrand.accent)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.observation.retainedIdentity?.email ?? title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let sync, hasIdentity {
                        NotebookWorkspaceSyncStatus(controller: sync)
                    } else {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
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
