import AccountKit
import AuthenticationServices
import SwiftUI

/// First screen when signed out: Apple, Google or email.
struct WelcomeView: View {
    let account: AccountController
    let configuration: AppConfiguration

    @State private var showingEmail = false
    @State private var emailMode = EmailAuthForm.Mode.logIn
    @State private var appleNonce: String?
    @State private var busyProvider: Provider?
    @State private var error: UserFacingError?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private enum Provider { case apple, google }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                header
                Spacer(minLength: 24)
                buttons
                    .padding(.horizontal, 24)
                legal
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background.ignoresSafeArea())
            .navigationDestination(isPresented: $showingEmail) {
                EmailAuthView(account: account, initialMode: emailMode)
            }
            .alert(item: $error) { error in
                Alert(title: Text(error.title), message: Text(error.message))
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.16), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .center
        )
    }

    private var header: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 88, height: 88)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 16, y: 8)
                Image(systemName: "sterlingsign.circle.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            Text("DayLedger")
                .font(.largeTitle.bold())
            Text("See where your day went — every place you visited and what you spent there, side by side.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 10) {
                FeatureRow(icon: "building.columns", text: "Read-only bank spending, sorted for you")
                FeatureRow(icon: "mappin.and.ellipse", text: "Places logged automatically")
                FeatureRow(icon: "icloud", text: "Synced and backed up to your account")
            }
            .padding(.top, 8)
        }
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            appleButton

            Button {
                signInWithGoogle()
            } label: {
                HStack(spacing: 8) {
                    if busyProvider == .google {
                        ProgressView()
                    } else {
                        Image(systemName: "g.circle.fill")
                            .font(.title3)
                            .accessibilityHidden(true)
                    }
                    Text("Continue with Google")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.plain)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(.separator), lineWidth: 0.5))
            .accessibilityIdentifier("continueWithGoogle")

            Button {
                emailMode = .logIn
                showingEmail = true
            } label: {
                Label("Continue with email", systemImage: "envelope.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .accessibilityIdentifier("continueWithEmail")

            Button("New here? Create an account") {
                emailMode = .register
                showingEmail = true
            }
            .font(.subheadline.weight(.medium))
            .padding(.top, 4)
            .accessibilityIdentifier("createAccount")
        }
        .disabled(busyProvider != nil)
    }

    @ViewBuilder
    private var appleButton: some View {
        let button = SignInWithAppleButton(.continue) { request in
            let nonce = AppleSignInNonce.makeRawNonce()
            appleNonce = nonce
            request.requestedScopes = [.email]
            request.nonce = AppleSignInNonce.sha256(nonce)
        } onCompletion: { result in
            handleApple(result)
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("continueWithApple")

        if account.isConfigured {
            button
        } else {
            // Without a backend the Apple sheet would only lead to an error, so explain straight away.
            button
                .allowsHitTesting(false)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { error = UserFacingError.auth(.notConfigured) }
                        .accessibilityLabel("Continue with Apple")
                        .accessibilityAddTraits(.isButton)
                }
        }
    }

    private var legal: some View {
        Group {
            if let terms = configuration.termsURL, let privacy = configuration.privacyURL {
                Text(Self.legalMarkdown(terms: terms, privacy: privacy))
            } else {
                Text("Your bank, Google and AI keys never leave this iPhone.")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    /// Built as a `String` first: Markdown links are only parsed from a complete string, not from
    /// interpolated placeholders.
    static func legalMarkdown(terms: URL, privacy: URL) -> LocalizedStringKey {
        let markdown: String = "By continuing you agree to the [Terms of Use](\(terms.absoluteString)) and [Privacy Policy](\(privacy.absoluteString))."
        return LocalizedStringKey(markdown)
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            busyProvider = .apple
            Task {
                defer { busyProvider = nil }
                do {
                    try await account.signInWithApple(authorization, rawNonce: appleNonce)
                } catch {
                    self.error = UserFacingError.account(error)
                }
            }
        case .failure(let failure):
            if let authError = failure as? ASAuthorizationError, authError.code == .canceled { return }
            error = UserFacingError(title: "Couldn't sign in with Apple", message: failure.localizedDescription)
        }
    }

    private func signInWithGoogle() {
        guard account.isConfigured else {
            error = UserFacingError.auth(.notConfigured)
            return
        }
        busyProvider = .google
        Task {
            defer { busyProvider = nil }
            do {
                try await account.signInWithGoogle(using: webAuthenticationSession)
            } catch {
                self.error = UserFacingError.account(error)
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
        }
    }
}
