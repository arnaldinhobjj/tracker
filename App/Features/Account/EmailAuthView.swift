import AccountKit
import SwiftUI

/// Email Log in / Register, with forgot password and the "check your email" step.
struct EmailAuthView: View {
    let account: AccountController

    @State private var form: EmailAuthForm
    @State private var showPassword = false
    @State private var attemptedSubmit = false
    @State private var touched: Set<Field> = []
    @State private var isWorking = false
    @State private var isSendingReset = false
    @State private var error: UserFacingError?
    @State private var confirmationEmail: String?
    @State private var resetSentTo: String?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case email, password, confirm }

    init(account: AccountController, initialMode: EmailAuthForm.Mode = .logIn) {
        self.account = account
        _form = State(initialValue: EmailAuthForm(mode: initialMode))
    }

    var body: some View {
        Group {
            if let confirmationEmail {
                CheckEmailView(email: confirmationEmail) {
                    self.confirmationEmail = nil
                    form.mode = .logIn
                    form.password = ""
                    form.confirmPassword = ""
                    attemptedSubmit = false
                    touched = []
                }
            } else {
                formView
            }
        }
        .navigationTitle(confirmationEmail == nil ? form.mode.title : "")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $error) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
        .alert("Check your email", isPresented: Binding(get: { resetSentTo != nil }, set: { if !$0 { resetSentTo = nil } })) {
            Button("OK") {}
        } message: {
            resetSentTo.map { Text("If an account exists for \($0), we've sent a link to reset your password. Open it on this iPhone.") }
                ?? Text("If an account exists for that address, we've sent a link to reset your password. Open it on this iPhone.")
        }
    }

    private var formView: some View {
        Form {
            Section {
                Picker("Mode", selection: $form.mode) {
                    ForEach(EmailAuthForm.Mode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("authModePicker")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Email", text: $form.email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .email)
                        .onSubmit { focus = .password }
                        .accessibilityIdentifier("emailField")
                    inlineError(for: .email, message: form.emailError)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        passwordField("Password", text: $form.password, field: .password)
                            .textContentType(form.mode == .register ? .newPassword : .password)
                            .submitLabel(form.mode == .register ? .next : .go)
                            .onSubmit {
                                if form.mode == .register { focus = .confirm } else { submit() }
                            }
                            .accessibilityIdentifier("passwordField")
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    inlineError(for: .password, message: form.passwordError)
                }

                if form.mode == .register {
                    VStack(alignment: .leading, spacing: 4) {
                        passwordField("Confirm password", text: $form.confirmPassword, field: .confirm)
                            .textContentType(.newPassword)
                            .submitLabel(.go)
                            .onSubmit(submit)
                            .accessibilityIdentifier("confirmPasswordField")
                        inlineError(for: .confirm, message: form.confirmError)
                    }
                }
            } footer: {
                if form.mode == .register {
                    VStack(alignment: .leading, spacing: 4) {
                        PasswordRule(text: "At least \(EmailAuthForm.minimumPasswordLength) characters", isMet: form.hasMinimumLength)
                        PasswordRule(text: "Both passwords match", isMet: form.passwordsMatch)
                    }
                    .padding(.top, 4)
                }
            }

            Section {
                Button(action: submit) {
                    HStack {
                        Spacer()
                        if isWorking {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Text(form.mode == .logIn ? "Log in" : "Create account")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .frame(minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .disabled(isWorking)
                .accessibilityIdentifier("submitAuth")

                if form.mode == .logIn {
                    Button {
                        sendReset()
                    } label: {
                        HStack {
                            Spacer()
                            if isSendingReset { ProgressView() } else { Text("Forgot password?") }
                            Spacer()
                        }
                    }
                    .font(.subheadline)
                    .listRowBackground(Color.clear)
                    .disabled(isSendingReset || isWorking)
                    .accessibilityIdentifier("forgotPassword")
                }
            } footer: {
                if form.mode == .register {
                    Text("We'll email you a link to confirm your address.")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: form.mode) { _, _ in
            attemptedSubmit = false
            touched = []
            form.confirmPassword = ""
        }
        .onChange(of: focus) { previous, _ in
            if let previous { touched.insert(previous) }
        }
        .onAppear { focus = .email }
    }

    @ViewBuilder
    private func passwordField(_ title: String, text: Binding<String>, field: Field) -> some View {
        Group {
            if showPassword {
                TextField(title, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                SecureField(title, text: text)
            }
        }
        .focused($focus, equals: field)
    }

    @ViewBuilder
    private func inlineError(for field: Field, message: String?) -> some View {
        if let message, attemptedSubmit || touched.contains(field) {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .transition(.opacity)
        }
    }

    private func submit() {
        attemptedSubmit = true
        guard form.canSubmit, !isWorking else { return }
        focus = nil
        isWorking = true
        let snapshot = form
        Task {
            defer { isWorking = false }
            do {
                switch snapshot.mode {
                case .logIn:
                    try await account.signIn(email: snapshot.trimmedEmail, password: snapshot.password)
                case .register:
                    if let email = try await account.signUp(email: snapshot.trimmedEmail, password: snapshot.password) {
                        confirmationEmail = email
                    }
                }
            } catch {
                self.error = UserFacingError.account(error)
            }
        }
    }

    private func sendReset() {
        touched.insert(.email)
        guard form.canRequestReset else {
            error = UserFacingError(title: "Enter your email first", message: "Type the email address you registered with, then tap \"Forgot password?\" again.")
            return
        }
        isSendingReset = true
        let email = form.trimmedEmail
        Task {
            defer { isSendingReset = false }
            do {
                try await account.sendPasswordReset(email: email)
                resetSentTo = email
            } catch {
                self.error = UserFacingError.account(error)
            }
        }
    }
}

private struct PasswordRule: View {
    let text: String
    let isMet: Bool

    var body: some View {
        Label(text, systemImage: isMet ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isMet ? Color.green : Color.secondary)
            .font(.footnote)
            .animation(.default, value: isMet)
    }
}

/// Shown after registering when the account needs its email confirmed.
private struct CheckEmailView: View {
    let email: String
    var backToLogIn: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "envelope.badge")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
            Text("Check your email")
                .font(.title.bold())
            Text("We've sent a confirmation link to **\(email)**. Open it on this iPhone to finish creating your account.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text("Can't find it? Look in your junk folder.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: backToLogIn) {
                Text("Back to log in")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 12))
        }
        .padding(24)
        .accessibilityIdentifier("checkYourEmail")
    }
}

/// Opened from a password-reset link.
struct NewPasswordView: View {
    let account: AccountController

    @State private var password = ""
    @State private var confirm = ""
    @State private var isSaving = false
    @State private var error: UserFacingError?
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        password.count >= EmailAuthForm.minimumPasswordLength && password == confirm
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                    SecureField("Confirm new password", text: $confirm)
                        .textContentType(.newPassword)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        PasswordRule(text: "At least \(EmailAuthForm.minimumPasswordLength) characters", isMet: password.count >= EmailAuthForm.minimumPasswordLength)
                        PasswordRule(text: "Both passwords match", isMet: !confirm.isEmpty && password == confirm)
                    }
                }
            }
            .navigationTitle("Choose a new password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", action: save).disabled(!isValid)
                    }
                }
            }
            .alert(item: $error) { error in
                Alert(title: Text(error.title), message: Text(error.message))
            }
        }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await account.updatePassword(password)
                dismiss()
            } catch {
                self.error = UserFacingError.account(error)
            }
        }
    }
}
