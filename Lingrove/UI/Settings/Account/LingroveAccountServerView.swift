// Adapted from Nibomo Settings/Account/ServerSettingsView.swift (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveCloud
import SwiftUI

/// The server screen owns only a confirmation intent and borrows endpoint drafts from Settings.
/// Current destination and editable inputs stay visibly distinct, as in Nibomo’s server form.
/// Applying invokes the existing local configuration policy; merely typing contacts no server.
struct LingroveAccountServerView: View {
    @ObservedObject var account: AccountSessionService
    @Binding var api: String
    @Binding var auth: String
    @State private var confirmingApply = false
    @State private var removingConnection = false

    private var matchesSaved: Bool {
        AccountConfigurationPolicy.matchesSavedConnection(api: api, auth: auth, saved: account.configuration)
    }

    var body: some View {
        LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 0) {
            Form {
                Section(LingroveNibomoAccountCopy.text("settings.account.server.section.currentServer")) {
                    if let current = account.configuration {
                        destination(LingroveNibomoAccountCopy.text("settings.account.server.apiUrl"), current.apiBaseURL.absoluteString)
                        destination(LingroveNibomoAccountCopy.text("settings.account.server.authUrl"), current.authBaseURL.absoluteString)
                    } else {
                        Text(AccountPresentation.title(.unconfigured)).foregroundStyle(.secondary)
                    }
                }
                Section(String(localized: "Account service", table: "Account")) {
                    Text(String(localized: """
                        Choose services you trust. Email, codes and session tokens go to the authentication service; the API \
                        confirms your identity. Changing the connection signs out on this Mac. No service is contacted until \
                        you sign in or restore a saved session.
                        """, table: "Account"))
                        .foregroundStyle(.secondary)
                    TextField(String(localized: "API base URL (including /v1)", table: "Account"), text: $api,
                              prompt: Text(verbatim: "https://api.example.com/v1"))
                        .textContentType(.URL).autocorrectionDisabled().accessibilityIdentifier("account.apiURL")
                    TextField(String(localized: "Authentication base URL", table: "Account"), text: $auth,
                              prompt: Text(verbatim: "https://auth.example.com"))
                        .textContentType(.URL).autocorrectionDisabled().accessibilityIdentifier("account.authURL")
                    if let issue = account.issue {
                        Text(AccountPresentation.message(issue)).foregroundStyle(.red).accessibilityIdentifier("account.issue")
                    }
                    Button(String(localized: "Save connection", table: "Account")) {
                        removingConnection = false; confirmingApply = true
                    }
                        .disabled(matchesSaved || account.state.isBusy)
                        .accessibilityIdentifier("account.saveConnection")
                }
                if account.configuration != nil {
                    Section {
                        Button(String(localized: "Remove connection", table: "Account"), role: .destructive) {
                            removingConnection = true; confirmingApply = true
                        }.accessibilityIdentifier("account.removeConnection")
                    }
                }
            }.formStyle(.grouped)
        }
        .navigationTitle(LingroveNibomoAccountCopy.text("settings.account.advanced.server"))
        .alert(removingConnection ? String(localized: "Remove connection", table: "Account")
            : LingroveNibomoAccountCopy.text("settings.account.server.confirmationTitle.apply"), isPresented: $confirmingApply) {
            Button(LingroveNibomoAccountCopy.text("common.cancel"), role: .cancel) { }
            Button(removingConnection ? String(localized: "Remove connection", table: "Account")
                : LingroveNibomoAccountCopy.text("settings.account.server.confirmationButton.apply"), role: .destructive) {
                if removingConnection {
                    if account.removeConfiguration() { api = ""; auth = "" }
                } else {
                    _ = account.configure(api: api, auth: auth)
                }
            }
        } message: {
            if removingConnection {
                Text(String(localized: """
                    This clears this Mac's session. It does not delete your account or sign out other devices.
                    """, table: "Account"))
            } else { Text(LingroveNibomoAccountCopy.text("settings.account.server.confirmationMessage")) }
        }
        .accessibilityIdentifier("account.server.screen")
    }

    private func destination(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).font(.caption.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
