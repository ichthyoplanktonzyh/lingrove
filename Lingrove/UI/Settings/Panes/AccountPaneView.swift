import SwiftUI

/// Native account settings borrows the process-owned session service. Only editable form drafts
/// live in `@State`; no view creates a transport, reads Keychain, or owns a refresh task. Observable
/// state therefore survives Settings closure, while passwords/tokens never enter the view tree.
struct AccountPaneView: View {
    @ObservedObject var account: AccountSessionService
    @State private var api = ""
    @State private var auth = ""
    @State private var email = ""
    @State private var code = ""

    var body: some View {
        SettingsPaneScaffold {
            Section {
                HStack {
                    if account.state.isBusy { ProgressView().controlSize(.small) }
                    Text(AccountPresentation.title(account.state))
                        .font(.headline)
                        .accessibilityIdentifier("account.status")
                    Spacer()
                }
                if let issue = account.issue {
                    Text(AccountPresentation.message(issue))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.issue")
                }
                sessionControls
            } header: {
                Text(String(localized: "Account", table: "Account"))
            } footer: {
                Text(String(localized: """
                    Signing in confirms your identity only. Your local library stays on this Mac; account sync is not \
                    connected.
                    """, table: "Account"))
            }
            .settingsItem(.accountSession)

            if showsSignIn {
                signInSection
            }

            Section {
                TextField(String(localized: "API base URL (including /v1)", table: "Account"), text: $api,
                    prompt: Text(verbatim: "https://api.example.com/v1"))
                    .textContentType(.URL)
                    .accessibilityIdentifier("account.apiURL")
                TextField(String(localized: "Authentication base URL", table: "Account"), text: $auth,
                    prompt: Text(verbatim: "https://auth.example.com"))
                    .textContentType(.URL)
                    .accessibilityIdentifier("account.authURL")
                HStack {
                    Button(String(localized: "Save connection", table: "Account")) {
                        if account.configure(api: api, auth: auth) { code = "" }
                    }
                    .accessibilityIdentifier("account.saveConnection")
                    if account.configuration != nil {
                        Button(String(localized: "Remove connection", table: "Account")) {
                            if account.removeConfiguration() {
                                api = ""
                                auth = ""
                                code = ""
                            }
                        }
                    }
                }
            } header: {
                Text(String(localized: "Account service", table: "Account"))
            } footer: {
                Text(String(localized: """
                    Choose services you trust. Email, codes and session tokens go to the authentication service; the API \
                    confirms your identity. Changing the connection signs out on this Mac. No service is contacted until \
                    you sign in or restore a saved session.
                    """, table: "Account"))
            }
            .settingsItem(.accountConnection)
        }
        .onAppear {
            api = account.configuration?.apiBaseURL.absoluteString ?? ""
            auth = account.configuration?.authBaseURL.absoluteString ?? ""
            email = account.codePrompt?.email ?? ""
        }
        .onChange(of: account.codePrompt?.email) { _, newEmail in
            if let newEmail { email = newEmail }
            code = ""
        }
    }

    private var showsSignIn: Bool {
        guard account.configuration != nil else { return false }
        return switch account.state {
        case .signedOut, .credentialsInvalid, .awaitingCode, .working(.sendingCode), .working(.verifyingCode): true
        default: false
        }
    }

    private var connectionIsSaved: Bool {
        AccountConfigurationPolicy.matchesSavedConnection(api: api, auth: auth, saved: account.configuration)
    }

    @ViewBuilder
    private var sessionControls: some View {
        switch account.state {
        case .signedIn(let identity):
            Text(identity.email ?? identity.userID).textSelection(.enabled)
            signOutButton
        case .offline(let identity):
            if let identity { Text(identity.email ?? identity.userID).textSelection(.enabled) }
            Text(String(localized: """
                Your saved session is not confirmed online. Local writing and learning remain available.
                """, table: "Account"))
                .foregroundStyle(.secondary)
            HStack {
                Button(String(localized: "Retry session", table: "Account")) { account.retrySession() }
                    .accessibilityIdentifier("account.retrySession")
                signOutButton
            }
        case .working(.restoring), .working(.refreshing):
            signOutButton
        case .signedOut where account.issue == .secureStorage:
            // A failed Keychain clear is retryable even though the durable restore gate is shut.
            signOutButton
        default:
            EmptyView()
        }
    }

    private var signOutButton: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(String(localized: "Sign out on this Mac", table: "Account")) { account.signOut(); code = "" }
                .accessibilityIdentifier("account.signOut")
            Text(String(localized: """
                This clears this Mac's session. It does not delete your account or sign out other devices.
                """, table: "Account"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var signInSection: some View {
        Section {
            if !connectionIsSaved {
                Label(String(localized: "Save connection", table: "Account"), systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            if let prompt = account.codePrompt {
                LabeledContent(String(localized: "Email", table: "Account"), value: prompt.email)
                SecureField(String(localized: "Eight-digit code", table: "Account"), text: $code)
                    .textContentType(.oneTimeCode)
                    .accessibilityIdentifier("account.code")
                    .onSubmit { if connectionIsSaved { account.submitCode(code) } }
                    .disabled(account.state.isBusy || prompt.isExpired || !connectionIsSaved)
                HStack {
                    Button(String(localized: "Verify and sign in", table: "Account")) { account.submitCode(code) }
                        .disabled(account.state.isBusy || prompt.isExpired || code.isEmpty || !connectionIsSaved)
                        .accessibilityIdentifier("account.verify")
                    Button(String(localized: "Resend code", table: "Account")) { code = ""; account.resendCode() }
                        .disabled(account.state.isBusy || !connectionIsSaved)
                        .accessibilityIdentifier("account.resend")
                    Button(String(localized: "Cancel sign-in", table: "Account")) { account.cancelSignIn(); code = "" }
                        .accessibilityIdentifier("account.cancel")
                }
            } else {
                TextField(String(localized: "Email", table: "Account"), text: $email)
                    .textContentType(.emailAddress)
                    .accessibilityIdentifier("account.email")
                    .disabled(account.state.isBusy || !connectionIsSaved)
                    .onSubmit { if connectionIsSaved { account.requestCode(email: email) } }
                HStack {
                    Button(String(localized: "Send sign-in code", table: "Account")) { account.requestCode(email: email) }
                        .disabled(account.state.isBusy || email.isEmpty || !connectionIsSaved)
                        .accessibilityIdentifier("account.sendCode")
                    if account.state.isBusy {
                        Button(String(localized: "Cancel sign-in", table: "Account")) { account.cancelSignIn() }
                            .accessibilityIdentifier("account.cancel")
                    }
                }
            }
        } header: {
            Text(String(localized: "Email sign-in", table: "Account"))
        } footer: {
            Text(String(localized: """
                Codes expire after three minutes. Resend may return the code already sent; the service checks its \
                remaining validity.
                """, table: "Account"))
        }
    }
}
