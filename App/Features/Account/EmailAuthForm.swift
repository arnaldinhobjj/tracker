import Foundation

/// Validation for the email Log in / Register form. Pure, so it is unit tested.
struct EmailAuthForm: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case logIn
        case register

        var id: String { rawValue }
        var title: String { self == .logIn ? "Log in" : "Register" }
    }

    static let minimumPasswordLength = 8

    var mode: Mode
    var email = ""
    var password = ""
    var confirmPassword = ""

    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Debug builds accept the developer username "admin" in the Log in email field.
    var isDeveloperUsername: Bool {
        #if DEBUG
        return mode == .logIn && DeveloperLogin.isDeveloperUsername(email)
        #else
        return false
        #endif
    }

    static func isValidEmail(_ email: String) -> Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 254, !value.contains(" ") else { return false }
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = parts[1]
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty } && (labels.last?.count ?? 0) >= 2
    }

    var emailError: String? {
        if trimmedEmail.isEmpty { return "Enter your email address." }
        if isDeveloperUsername { return nil }
        return Self.isValidEmail(trimmedEmail) ? nil : "That doesn't look like an email address."
    }

    var hasMinimumLength: Bool { password.count >= Self.minimumPasswordLength }
    var passwordsMatch: Bool { !confirmPassword.isEmpty && password == confirmPassword }

    var passwordError: String? {
        if password.isEmpty { return mode == .logIn ? "Enter your password." : "Choose a password." }
        // Existing accounts may predate the rules, so only new passwords are checked.
        if mode == .register && !hasMinimumLength {
            return "Use at least \(Self.minimumPasswordLength) characters."
        }
        return nil
    }

    var confirmError: String? {
        guard mode == .register else { return nil }
        if confirmPassword.isEmpty { return "Type your password again." }
        return passwordsMatch ? nil : "The passwords don't match."
    }

    var canSubmit: Bool {
        emailError == nil && passwordError == nil && confirmError == nil
    }

    /// For "Forgot password?": only the email needs to be valid.
    var canRequestReset: Bool {
        !trimmedEmail.isEmpty && Self.isValidEmail(trimmedEmail)
    }
}
