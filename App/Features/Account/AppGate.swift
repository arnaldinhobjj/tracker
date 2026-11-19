import AccountKit
import SwiftUI

/// Whether DayLedger Pro features (cloud sync, AI suggestions) can be used right now.
///
/// DayLedger is local-first: Today, widgets, bank connections, Places and the calendar diary work
/// without an account. Only Pro features need an account with an active subscription.
enum ProAccess: Equatable {
    case available
    /// No account yet: sign in (or create one) first.
    case signInRequired
    /// Signed in without an active subscription or trial.
    case subscriptionRequired
    /// Signed in; asking the server (or StoreKit) about the subscription.
    case checking
    /// Release build without an account backend: Pro can't be offered.
    case unavailable
}

/// The account sheets presented over the app.
enum AccountSheet: String, Identifiable {
    case signIn
    case paywall

    var id: String { rawValue }
}

/// The gating rules, kept pure so they can be unit tested.
enum AppGate {
    enum Entitlement: Equatable {
        case unknown
        case entitled
        case notEntitled
    }

    static func proAccess(
        isUITesting: Bool,
        isDeveloperAccount: Bool,
        isConfigured: Bool,
        isDebugBuild: Bool,
        isSignedIn: Bool,
        entitlement: Entitlement
    ) -> ProAccess {
        // UI tests and the no-credentials demo (`-UITestMockData`) have no accounts but exercise
        // the opt-in flows (e.g. the AI assistant's off state).
        if isUITesting { return .available }
        // Debug-only local account: always subscribed, never talks to the backend.
        if isDeveloperAccount && isSignedIn { return .available }
        if !isSignedIn {
            // Debug builds still offer the login screens without a backend, so they can be tried
            // (and the developer login used).
            return isConfigured || isDebugBuild ? .signInRequired : .unavailable
        }
        switch entitlement {
        case .unknown: return .checking
        case .entitled: return .available
        case .notEntitled: return .subscriptionRequired
        }
    }

    /// The sheet that unlocks Pro from the given state, if any.
    static func sheet(toUnlock access: ProAccess) -> AccountSheet? {
        switch access {
        case .signInRequired: return .signIn
        case .subscriptionRequired, .checking: return .paywall
        case .available, .unavailable: return nil
        }
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

extension AppEnvironment {
    var proAccess: ProAccess {
        AppGate.proAccess(
            isUITesting: isUITesting,
            isDeveloperAccount: account.isDeveloperAccount,
            isConfigured: account.isConfigured,
            isDebugBuild: AppGate.isDebugBuild,
            isSignedIn: account.isSignedIn,
            entitlement: subscriptions.gateEntitlement
        )
    }

    /// Opens whatever unlocks Pro: sign-in when signed out, the paywall when signed in.
    func requestPro() {
        accountSheet = AppGate.sheet(toUnlock: proAccess)
    }
}

/// The app itself, always: nothing is locked behind an account. Sign-in and the paywall appear as
/// sheets when the user asks for a Pro feature (or opens them from Settings).
struct AppGateView: View {
    @Bindable var environment: AppEnvironment
    @State private var paywallAfterCheck = false

    private var account: AccountController { environment.account }

    private func showPaywallIfNeeded(_ access: ProAccess) {
        guard paywallAfterCheck, access != .checking else { return }
        paywallAfterCheck = false
        if access == .subscriptionRequired { environment.accountSheet = .paywall }
    }

    var body: some View {
        Group {
            RootView(environment: environment)
                .sheet(item: $environment.accountSheet) { sheet in
                    switch sheet {
                    case .signIn:
                        WelcomeView(account: account, configuration: environment.configuration) {
                            environment.accountSheet = nil
                        }
                    case .paywall:
                        PaywallView(subscriptions: environment.subscriptions, account: account,
                                    configuration: environment.configuration) {
                            environment.accountSheet = nil
                        }
                    }
                }
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            guard environment.accountSheet != nil else { return }
            environment.accountSheet = nil
            // Signed in from the sign-in sheet: once the subscription check finishes, show the
            // paywall unless they're already subscribed (no paywall flash for subscribers).
            paywallAfterCheck = signedIn
            if signedIn { showPaywallIfNeeded(environment.proAccess) }
        }
        .onChange(of: environment.proAccess) { _, access in
            if access == .available { environment.accountSheet = nil }
            showPaywallIfNeeded(access)
        }
        .sheet(isPresented: Binding(get: { account.isChoosingNewPassword }, set: { account.isChoosingNewPassword = $0 })) {
            NewPasswordView(account: account)
        }
        .alert(item: Binding(get: { account.linkError }, set: { account.linkError = $0 })) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
    }
}

/// Shown in place of a Pro feature that isn't unlocked.
struct ProUpsellView: View {
    let environment: AppEnvironment
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            switch environment.proAccess {
            case .signInRequired:
                Button("Sign in to get DayLedger Pro") { environment.requestPro() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("proSignIn")
            case .subscriptionRequired:
                Button("See DayLedger Pro") { environment.requestPro() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("proPaywall")
            case .checking:
                ProgressView()
            case .unavailable:
                Text("DayLedger Pro isn't available in this build.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .available:
                EmptyView()
            }
        }
    }
}
