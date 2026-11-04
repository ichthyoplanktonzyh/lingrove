// Account page structure adapted from Nibomo AccountStatusView.swift (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveCloud
import SwiftUI

/// The Settings window lends its account navigation/draft owner and the process-owned services.
/// This pane renders identity first, then links to sync and secondary service configuration. Its
/// local navigation has an explicit path so an external Account action always reaches the overview
/// without discarding URL drafts or performing authentication, ownership adoption or sync opt-in.
struct AccountPaneView: View {
    @ObservedObject var account: AccountSessionService
    var syncController: MacNotebookSyncController?
    @ObservedObject var navigation = AccountSettingsNavigation()
    @State private var signingIn = false
    @State private var confirmingSignOut = false

    private var connectionIsSaved: Bool { navigation.matches(account.configuration) }
    private var hasDraftChanges: Bool { navigation.hasChanges(comparedWith: account.configuration) }

    var body: some View {
        VStack(spacing: 0) {
            // Settings owns the window toolbar. Account routes use a local, constant-height
            // header so a nested NavigationStack cannot insert/remove native titlebar rows.
            HStack(spacing: 12) {
                Button { navigation.showOverview() } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel(String(localized: "Back"))
                .accessibilityIdentifier("account.back")
                .opacity(navigation.path.isEmpty ? 0 : 1)
                .disabled(navigation.path.isEmpty)
                .accessibilityHidden(navigation.path.isEmpty)
                Text(pageTitle).font(.headline)
                Spacer()
                HStack(spacing: 5) {
                    LingroveWhaleGlyph(size: 11, tint: LingroveBrand.accent)
                    Text(ProductIdentity.appDisplayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LingroveBrand.accent)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(LingroveBrand.accent.opacity(0.11)))
                .accessibilityHidden(true)
            }.padding(.horizontal, 20).frame(height: 44)
            Divider()
            Group {
                switch navigation.path.last {
                case .service:
                    LingroveAccountServerView(account: account, api: $navigation.api, auth: $navigation.auth)
                case .sync:
                    SettingsPaneScaffold(callout: draftCallout) {
                        if let syncController {
                            AccountNotebookSyncSection(controller: syncController).disabled(!connectionIsSaved)
                        }
                    }.accessibilityIdentifier("account.sync.screen")
                case nil: overview
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $signingIn, onDismiss: { account.cancelSignIn() }, content: {
            LingroveAccountSignInSheet(account: account, connectionIsSaved: connectionIsSaved,
                hasDraftChanges: hasDraftChanges, onOpenService: {
                    account.cancelSignIn()
                    signingIn = false
                    navigation.show(.service)
                })
        })
        .alert(String(localized: "Sign out on this Mac", table: "Account"), isPresented: $confirmingSignOut) {
            Button(LingroveNibomoAccountCopy.text("common.cancel"), role: .cancel) { }
            Button(String(localized: "Sign out on this Mac", table: "Account"), role: .destructive) { account.signOut() }
                .accessibilityIdentifier("account.signOut.confirm")
        } message: {
            Text(String(localized: """
                This clears this Mac's session. It does not delete your account or sign out other devices.
                """, table: "Account"))
        }
        .onAppear { navigation.reconcile(configuration: account.configuration) }
        .onChange(of: account.configuration) { _, configuration in navigation.reconcile(configuration: configuration) }
    }

    private var pageTitle: String {
        switch navigation.path.last {
        case .service: String(localized: "Account service", table: "Account")
        case .sync: String(localized: "Notebook sync", table: "NotebookSync")
        case nil: String(localized: "Account", table: "Account")
        }
    }

    private var overview: some View {
        SettingsPaneScaffold(callout: draftCallout) {
            if let issue = account.issue {
                Section {
                    SettingsCalloutView(callout: .init(tone: .warning, message: AccountPresentation.message(issue)))
                        .accessibilityIdentifier("account.issue")
                }
            }
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        if account.state.isBusy { ProgressView().controlSize(.small) }
                        Text(AccountPresentation.title(account.state)).accessibilityIdentifier("account.status")
                    }
                } label: {
                    SettingsRowLabel(title: LingroveNibomoAccountCopy.text("settings.account.status.state"),
                        systemImage: "person.crop.circle")
                }
                if let identity = account.observation.retainedIdentity {
                    LabeledContent(LingroveNibomoAccountCopy.text("settings.account.status.linkedEmail")) {
                        Text(identity.email ?? identity.userID).textSelection(.enabled)
                    }
                }
                sessionControls
            } header: {
                Text(LingroveNibomoAccountCopy.text("settings.account.status.section.accountStatus"))
            } footer: {
                Text(String(localized: """
                    Signing in only confirms your identity. Choose a workspace, decide what to do with \
                    local material, then enable sync.
                    """, table: "NotebookSync"))
            }
            .settingsItem(.accountSession)

            if let syncController {
                Section {
                    AccountSyncNavigationRow(controller: syncController, open: { navigation.show(.sync) })
                }
            }
            Section {
                Button { navigation.show(.service) } label: {
                    SettingsRowLabel(title: String(localized: "Account service", table: "Account"),
                        description: String(localized: "Advanced connection settings", table: "Account"),
                        systemImage: "server.rack")
                }
                .buttonStyle(.plain).accessibilityIdentifier("account.server")
            }
            Section {
                SettingsCalloutView(callout: .init(tone: .info,
                    message: String(localized: "Your local library, review and progress work without an account.", table: "Account")))
            }
        }
        .accessibilityIdentifier("account.overview")
    }

    private var draftCallout: SettingsPaneCallout? {
        guard hasDraftChanges else { return nil }
        return .init(tone: .warning, message: String(localized: """
            Connection changes are not saved. Save or revert them before signing in or syncing.
            """, table: "Account"))
    }

    @ViewBuilder private var sessionControls: some View {
        switch account.state {
        case .signedIn:
            HStack {
                if let syncController, syncController.enabled {
                    Button(LingroveNibomoAccountCopy.text("settings.account.status.syncNow")) { syncController.retry() }
                        .disabled(!connectionIsSaved)
                }
                Spacer()
                signOutButton
            }
        case .offline:
            HStack {
                Button(String(localized: "Retry session", table: "Account")) { account.retrySession() }
                    .disabled(!connectionIsSaved).accessibilityIdentifier("account.retrySession")
                Spacer()
                signOutButton
            }
        case .working(.restoring), .working(.refreshing): signOutButton
        case .signedOut where account.issue == .secureStorage:
            HStack { signInButton; Spacer(); signOutButton }
        default:
            HStack {
                signInButton
                Spacer()
            }
        }
    }

    private var signInButton: some View {
        // Opening login is always available, even before a release bundles a service.
        // The sheet explains missing configuration/drafts and gates every request.
        Button(String(localized: "Sign in or create an account", table: "Account")) { signingIn = true }
            .buttonStyle(.borderedProminent)
            .disabled(account.state.isBusy)
            .accessibilityIdentifier("account.signIn")
    }

    private var signOutButton: some View {
        Button(String(localized: "Sign out on this Mac", table: "Account"), role: .destructive) { confirmingSignOut = true }
            .accessibilityIdentifier("account.signOut")
    }
}

/// Only this row subscribes to sync while the overview is visible. It reports the real workspace
/// and corpus lane; opening the link has no effect on either the selected scope or sync consent.
private struct AccountSyncNavigationRow: View {
    @ObservedObject var controller: MacNotebookSyncController
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                SettingsRowLabel(title: String(localized: "Notebook sync", table: "NotebookSync"),
                    description: controller.selectedWorkspace?.name ?? MacNotebookSyncPresentation.title(controller.workspaceStatus),
                    systemImage: "arrow.triangle.2.circlepath")
                Spacer(minLength: 8)
                LingroveSyncStatusIndicator(status: controller.corpusStatus)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain).accessibilityIdentifier("account.sync.open")
    }
}
