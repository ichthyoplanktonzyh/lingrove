// Email/code forms extracted from Nibomo CloudSignInSheet and CloudOtpVerificationSheet (MIT).
// Copyright (c) 2026 Kirill Markin. License: Lingrove/Resources/NibomoUI-LICENSE.txt.
import LingroveCloud
import SwiftUI

/// Nibomo’s separate email and code screens, bound to Lingrove’s existing OTP facade. Only
/// text/focus/navigation belong to the sheet; challenge expiry, generation and credentials remain
/// service-owned. Reopening sees the same challenge without resending or recreating a session.
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
                .navigationTitle(LingroveNibomoAccountCopy.text("common.email"))
                .navigationDestination(isPresented: $showingCode) { codeForm }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(LingroveNibomoAccountCopy.text("common.close")) { account.cancelSignIn(); dismiss() }
                            .accessibilityIdentifier("account.cancel").keyboardShortcut(.cancelAction)
                    }
                }
        }
        .frame(width: 560, height: 480).tint(.orange).preferredColorScheme(.dark)
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
        LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 0) {
            Form {
                errorSection
                Section(LingroveNibomoAccountCopy.text("common.email")) {
                    TextField(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.emailPlaceholder"), text: $email)
                        .autocorrectionDisabled().textContentType(.emailAddress).focused($emailFocused)
                        .accessibilityIdentifier("account.email").onSubmit(sendCode)
                }.disabled(account.state.isBusy || !connectionIsSaved)
                Section {
                    Button(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.sendOneTimeCode"), action: sendCode)
                        .disabled(account.state.isBusy || email.isEmpty || !connectionIsSaved)
                        .accessibilityIdentifier("account.sendCode")
                    if account.state.isBusy { ProgressView().controlSize(.small) }
                }
            }.formStyle(.grouped)
        }
    }

    private var codeForm: some View {
        LingroveReadableContentLayout(maxWidth: lingroveReadableFormMaxWidth, horizontalPadding: 0) {
            Form {
                errorSection
                Section(LingroveNibomoAccountCopy.text("common.email")) {
                    Text(account.codePrompt?.email ?? email).textSelection(.enabled)
                }
                Section(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.oneTimeCode")) {
                    Text(LingroveNibomoAccountCopy.text(account.codePrompt?.isExpired == true
                        ? "settings.account.cloudSignIn.challengePrompt.expired" : "settings.account.cloudSignIn.challengePrompt.active"))
                        .foregroundStyle(.secondary)
                    if account.codePrompt?.isExpired == false {
                        TextField(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.codePlaceholder"), text: $code)
                            .autocorrectionDisabled().textContentType(.oneTimeCode).focused($codeFocused)
                            .accessibilityIdentifier("account.code").onSubmit(verifyCode)
                            .disabled(account.state.isBusy || !connectionIsSaved)
                        Button(LingroveNibomoAccountCopy.text("common.continue"), action: verifyCode)
                            .disabled(account.state.isBusy || code.isEmpty || !connectionIsSaved)
                            .accessibilityIdentifier("account.verify")
                    }
                    Button(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.resendCode")) {
                        guard connectionIsSaved, !account.state.isBusy else { return }
                        code = ""; account.resendCode()
                    }.disabled(account.state.isBusy || !connectionIsSaved).accessibilityIdentifier("account.resend")
                    if account.state.isBusy { ProgressView().controlSize(.small) }
                }
            }.formStyle(.grouped)
        }.navigationTitle(LingroveNibomoAccountCopy.text("settings.account.cloudSignIn.verifyCodeTitle"))
            .onAppear { codeFocused = account.codePrompt?.isExpired == false }
    }

    @ViewBuilder private var errorSection: some View {
        if !connectionIsSaved {
            Section { Label(String(localized: "Save connection", table: "Account"), systemImage: "exclamationmark.circle") }
        }
        if let issue = account.issue {
            Section { Text(AccountPresentation.message(issue)).foregroundStyle(.red).accessibilityIdentifier("account.issue") }
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
