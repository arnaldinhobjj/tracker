import AccountKit
import SwiftUI

/// Which screen the app shows at the top level.
enum AppGateState: Equatable {
    /// The app itself (`RootView`).
    case main
    /// Release build without `SUPABASE_URL`: nothing can be done without accounts.
    case accountsNotConfigured
    /// Signed out: welcome, log in, register.
    case signedOut
    /// Signed in; asking the server (or StoreKit) about the subscription.
    case checkingSubscription
    /// Signed in without an active subscription or trial.
    case paywall
}

/// The gating rules, kept pure so they can be unit tested.
enum AppGate {
    enum Entitlement: Equatable {
        case unknown
        case entitled
        case notEntitled
    }

    static func state(
        isUITesting: Bool,
        isDeveloperAccount: Bool,
        isConfigured: Bool,
        isDebugBuild: Bool,
        isSignedIn: Bool,
        entitlement: Entitlement
    ) -> AppGateState {
        // UI tests and the no-credentials demo (`-UITestMockData`) skip accounts entirely.
        if isUITesting { return .main }
        // Debug-only local account: always subscribed, never talks to the backend.
        if isDeveloperAccount && isSignedIn { return .main }
        if !isSignedIn {
            // Debug builds still show the login screens without a backend, so they can be tried
            // (and the developer login used). Release builds can't do anything without one.
            return isConfigured || isDebugBuild ? .signedOut : .accountsNotConfigured
        }
        switch entitlement {
        case .unknown: return .checkingSubscription
        case .entitled: return .main
        case .notEntitled: return .paywall
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

/// Shows the welcome screen, the paywall or the app, depending on the account.
struct AppGateView: View {
    let environment: AppEnvironment

    private var account: AccountController { environment.account }
    private var subscriptions: SubscriptionManager { environment.subscriptions }

    private var state: AppGateState {
        AppGate.state(
            isUITesting: environment.isUITesting,
            isDeveloperAccount: account.isDeveloperAccount,
            isConfigured: account.isConfigured,
            isDebugBuild: AppGate.isDebugBuild,
            isSignedIn: account.isSignedIn,
            entitlement: subscriptions.gateEntitlement
        )
    }

    var body: some View {
        Group {
            switch state {
            case .main:
                RootView(environment: environment)
            case .accountsNotConfigured:
                AccountsNotConfiguredView()
            case .signedOut:
                WelcomeView(account: account, configuration: environment.configuration)
            case .checkingSubscription:
                CheckingSubscriptionView()
                    .task { await subscriptions.refreshEntitlement() }
            case .paywall:
                PaywallView(subscriptions: subscriptions, account: account, configuration: environment.configuration)
            }
        }
        .animation(.default, value: state)
        .sheet(isPresented: Binding(get: { account.isChoosingNewPassword }, set: { account.isChoosingNewPassword = $0 })) {
            NewPasswordView(account: account)
        }
        .alert(item: Binding(get: { account.linkError }, set: { account.linkError = $0 })) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
    }
}

private struct CheckingSubscriptionView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Checking your subscription…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

/// Release builds without a backend configured.
struct AccountsNotConfiguredView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Accounts aren't set up yet", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text("This build of DayLedger isn't connected to an account server, so you can't log in. Please install the version from the App Store.")
        }
        .background(Color(.systemGroupedBackground))
    }
}
