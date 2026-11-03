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
    var hasDraftChanges = false
    var onOpenService: (() -> Void)?
    @State private var email = ""
    @State private var code = ""
    @State private var showingCode = false
    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            emailForm
                .navigationTitle(String(localized: "Sign in or create an account", table: "Account"))
                .navigationDestination(isPresented: codeRoute) { codeForm }
                .toolbar { closeToolbar }
        }
        .frame(width: 560, height: 500)
        .onAppear {
            email = account.codePrompt?.email ?? email
            showingCode = account.codePrompt != nil
            emailFocused = !showingCode
        }
        .onChange(of: account.codePrompt) { _, prompt in
            code = ""
            // Resend retires the old challenge before awaiting the new one. Keep its route
            // visible while sending, instead of briefly popping the user back to email.
            if prompt != nil { showingCode = true } else if account.state != .working(.sendingCode) { showingCode = false }
            codeFocused = prompt != nil
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

    /// Navigation writes this binding for Back. Programmatic challenge consumption writes the
    /// State directly: a successful verify clears its prompt before awaiting identity, and must
    /// keep that request alive. User Back, including during resend with no prompt, cancels it.
    private var codeRoute: Binding<Bool> {
        Binding(get: { showingCode }, set: { visible in
            if showingCode, !visible { account.cancelSignIn(); code = "" }
            showingCode = visible
        })
    }

    /// Each NavigationStack destination owns its toolbar on macOS. Applying the same control
    /// to both steps keeps direct cancellation available after the email form is pushed away.
    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(LingroveNibomoAccountCopy.text("common.close")) { account.cancelSignIn(); dismiss() }
                .accessibilityIdentifier("account.cancel").keyboardShortcut(.cancelAction)
        }
    }

    private var emailForm: some View {
        SettingsPaneScaffold {
            Section {
                Text(String(localized: "Use your email to sign in or create an account. No password is needed.", table: "Account"))
                    .foregroundStyle(.secondary)
            }
            errorSection
            Section {
                TextField(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.emailPlaceholder"), text: $email)
                    .autocorrectionDisabled().textContentType(.emailAddress).focused($emailFocused)
                    .accessibilityIdentifier("account.email").onSubmit(sendCode)
                    .disabled(account.state.isBusy || !requestsAllowed)
                HStack {
                    Button(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.sendOneTimeCode"), action: sendCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(account.state.isBusy || !validEmail || !requestsAllowed)
                        .accessibilityIdentifier("account.sendCode")
                    if account.state.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
            } header: { Text(LingroveNibomoAccountCopy.text("common.email")) }
            serviceSection
            Section {
                Text(String(localized: "Your local library, review and progress work without an account.", table: "Account"))
                    .foregroundStyle(.secondary)
            }
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
                        .disabled(account.state.isBusy || !requestsAllowed)
                }
                HStack {
                    if account.codePrompt?.isExpired == false {
                        Button(LingroveNibomoAccountCopy.text("common.continue"), action: verifyCode)
                            .buttonStyle(.borderedProminent)
                            .disabled(account.state.isBusy || !validCode || !requestsAllowed)
                            .accessibilityIdentifier("account.verify")
                    }
                    Button(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.resendCode")) {
                        guard requestsAllowed, !account.state.isBusy else { return }
                        code = ""
                        account.resendCode()
                    }
                    .disabled(account.state.isBusy || !requestsAllowed).accessibilityIdentifier("account.resend")
                    if account.state.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
            } header: {
                Text(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.oneTimeCode"))
            } footer: {
                Text(String(localized: "Codes expire after three minutes.", table: "Account"))
            }
        }
        .navigationTitle(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.verifyCodeTitle"))
        .onAppear { codeFocused = account.codePrompt?.isExpired == false }
        .toolbar { closeToolbar }
    }

    @ViewBuilder private var errorSection: some View {
        if account.configuration == nil {
            Section {
                SettingsCalloutView(callout: .init(tone: .info,
                    message: AccountPresentation.unavailableService(account.buildConfiguration)))
                    .accessibilityIdentifier("account.serviceUnavailable")
                serviceSettingsButton
            }
        } else if hasDraftChanges || !connectionIsSaved {
            Section {
                SettingsCalloutView(callout: .init(tone: .warning, message: String(localized: """
                    Connection changes are not saved. Save or revert them before signing in or syncing.
                    """, table: "Account")))
                serviceSettingsButton
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
        if let configuration = account.configuration, !hasDraftChanges {
            Section(String(localized: "Account service", table: "Account")) {
                LabeledContent(AccountPresentation.sourceTitle(account.connectionSource)) {
                    if account.connectionSource == .custom {
                        Text(configuration.authBaseURL.host() ?? configuration.authBaseURL.absoluteString)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder private var serviceSettingsButton: some View {
        if let onOpenService {
            Button(String(localized: "Account service", table: "Account"), action: onOpenService)
                .accessibilityIdentifier("account.openServiceSettings")
        }
    }

    private var validEmail: Bool { (try? AccountConfigurationPolicy.normalizedEmail(email)) != nil }
    private var validCode: Bool { (try? AccountConfigurationPolicy.normalizedCode(code)) != nil }
    private var requestsAllowed: Bool { connectionIsSaved && !hasDraftChanges && account.configuration != nil }

    private func sendCode() {
        guard requestsAllowed, !account.state.isBusy, validEmail else { return }
        account.requestCode(email: email)
    }
    private func verifyCode() {
        guard requestsAllowed, !account.state.isBusy,
              account.codePrompt?.isExpired == false, validCode else { return }
        account.submitCode(code)
    }
}
