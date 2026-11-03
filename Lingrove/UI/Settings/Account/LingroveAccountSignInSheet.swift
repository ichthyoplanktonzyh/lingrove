// Email/code forms extracted from Nibomo CloudSignInSheet and CloudOtpVerificationSheet (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveCloud
import SwiftUI

/// Only focus, entered text and the email/code route belong to this sheet. The app-owned account
/// facade owns challenge expiry, credentials and cancellation generations. Reopening observes an
/// existing challenge without resending. Every request remains gated by the saved service pair.
struct LingroveAccountSignInSheet: View {
    @ObservedObject var account: AccountSessionService
    let connectionIsSaved: Bool
    @State private var email = ""
    @State private var code = ""
    @State private var showingCode = false
    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            emailForm
                .navigationTitle(String(localized: "Email sign-in", table: "Account"))
                .navigationDestination(isPresented: $showingCode) { codeForm }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(LingroveNibomoAccountCopy.text("common.close")) { account.cancelSignIn(); dismiss() }
                            .accessibilityIdentifier("account.cancel").keyboardShortcut(.cancelAction)
                    }
                }
        }
        .frame(width: 560, height: 500)
        .onAppear {
            email = account.codePrompt?.email ?? email
            showingCode = account.codePrompt != nil
            emailFocused = !showingCode
        }
        .onChange(of: account.codePrompt) { _, prompt in
            code = ""
            showingCode = prompt != nil
            codeFocused = prompt != nil
        }
        .onChange(of: showingCode) { _, visible in
            if !visible, account.codePrompt != nil { account.cancelSignIn(); code = "" }
        }
        .onChange(of: account.state) { _, state in
            if case .signedIn = state { code = ""; dismiss() }
        }
        .onChange(of: account.observation.generation) { _, _ in
            code = ""
            if account.configuration == nil { dismiss() }
        }
        .interactiveDismissDisabled(account.state.isBusy)
        .accessibilityIdentifier("account.signIn.screen")
    }

    private var emailForm: some View {
        SettingsPaneScaffold {
            errorSection
            Section {
                TextField(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.emailPlaceholder"), text: $email)
                    .autocorrectionDisabled().textContentType(.emailAddress).focused($emailFocused)
                    .accessibilityIdentifier("account.email").onSubmit(sendCode)
                    .disabled(account.state.isBusy || !connectionIsSaved)
                HStack {
                    Button(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.sendOneTimeCode"), action: sendCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(account.state.isBusy || email.isEmpty || !connectionIsSaved)
                        .accessibilityIdentifier("account.sendCode")
                    if account.state.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
            } header: { Text(LingroveNibomoAccountCopy.text("common.email")) }
            serviceSection
        }
    }

    private var codeForm: some View {
        SettingsPaneScaffold {
            errorSection
            Section(LingroveNibomoAccountCopy.text("common.email")) {
                Text(account.codePrompt?.email ?? email).textSelection(.enabled)
            }
            Section {
                Text(LingroveNibomoAccountCopy.text(account.codePrompt?.isExpired == true
                    ? "settings.account.cloudSignIn.challengePrompt.expired" : "settings.account.cloudSignIn.challengePrompt.active"))
                    .foregroundStyle(.secondary)
                if account.codePrompt?.isExpired == false {
                    TextField(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.codePlaceholder"), text: $code)
                        .autocorrectionDisabled().textContentType(.oneTimeCode).focused($codeFocused)
                        .accessibilityIdentifier("account.code").onSubmit(verifyCode)
                        .disabled(account.state.isBusy || !connectionIsSaved)
                }
                HStack {
                    if account.codePrompt?.isExpired == false {
                        Button(LingroveNibomoAccountCopy.text("common.continue"), action: verifyCode)
                            .buttonStyle(.borderedProminent)
                            .disabled(account.state.isBusy || code.isEmpty || !connectionIsSaved)
                            .accessibilityIdentifier("account.verify")
                    }
                    Button(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.resendCode")) {
                        guard connectionIsSaved, !account.state.isBusy else { return }
                        code = ""
                        account.resendCode()
                    }
                    .disabled(account.state.isBusy || !connectionIsSaved).accessibilityIdentifier("account.resend")
                    if account.state.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
            } header: {
                Text(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.oneTimeCode"))
            } footer: {
                Text(String(localized: """
                    Codes expire after three minutes. Resend may return the code already sent; the service checks its remaining validity.
                    """, table: "Account"))
            }
        }
        .navigationTitle(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.verifyCodeTitle"))
        .onAppear { codeFocused = account.codePrompt?.isExpired == false }
    }

    @ViewBuilder private var errorSection: some View {
        if !connectionIsSaved {
            Section {
                SettingsCalloutView(callout: .init(tone: .warning, message: String(localized: """
                    Connection changes are not saved. Save or revert them before signing in or syncing.
                    """, table: "Account")))
            }
        }
        if let issue = account.issue {
            Section {
                SettingsCalloutView(callout: .init(tone: .warning, message: AccountPresentation.message(issue)))
                    .accessibilityIdentifier("account.issue")
            }
        }
    }

    @ViewBuilder private var serviceSection: some View {
        if let configuration = account.configuration {
            Section(String(localized: "Account service", table: "Account")) {
                LabeledContent(String(localized: "Authentication base URL", table: "Account")) {
                    Text(configuration.authBaseURL.absoluteString).font(.caption.monospaced())
                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
        }
    }

    private func sendCode() {
        guard connectionIsSaved, !account.state.isBusy, !email.isEmpty else { return }
        account.requestCode(email: email)
    }
    private func verifyCode() {
        guard connectionIsSaved, !account.state.isBusy, account.codePrompt?.isExpired == false else { return }
        account.submitCode(code)
    }
}
