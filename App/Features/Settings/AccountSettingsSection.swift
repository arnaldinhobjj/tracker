import AccountKit
import StoreKit
import SwiftUI

/// Settings → Account: signing in (optional: only DayLedger Pro needs an account), the plan,
/// cloud sync (encryption key, visit sync), managing the subscription, signing out and deleting
/// the account. Hidden in UI tests / demo data, which have no accounts.
struct AccountSettingsSection: View {
    let environment: AppEnvironment
    var onDataErased: () -> Void

    @State private var showingManageSubscription = false
    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @State private var isWorking = false
    @State private var error: UserFacingError?

    private var account: AccountController { environment.account }
    private var subscriptions: SubscriptionManager { environment.subscriptions }

    var body: some View {
        if let user = account.user {
            signedIn(user)
            if !account.isDeveloperAccount {
                CloudSyncSettingsSection(environment: environment)
            }
        } else if !environment.isUITesting {
            signedOut
        }
    }

    private var signedOut: some View {
        Section {
            if environment.proAccess == .unavailable {
                Text("Accounts aren't available in this build. Everything else works on this iPhone.")
                    .foregroundStyle(.secondary)
            } else {
                Button("Sign in or create an account") { environment.accountSheet = .signIn }
                    .accessibilityIdentifier("signIn")
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Optional. DayLedger works on this iPhone without an account. With an account and DayLedger Pro, your ledger syncs end-to-end encrypted and AI suggestions are available.")
        }
    }

    @ViewBuilder
    private func signedIn(_ user: AuthUser) -> some View {
        Section {
            LabeledContent("Email", value: user.email ?? "Hidden by Apple")
            LabeledContent("Plan", value: planDescription)
            if let planDate {
                LabeledContent(planDate.label, value: planDate.date.formatted(date: .abbreviated, time: .omitted))
            }

            if account.isDeveloperAccount {
                Label("Developer account (Debug build only): mock data, no cloud sync.", systemImage: "hammer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                if let lastSync = environment.cloudSync.lastSync {
                    LabeledContent("Last synced", value: lastSync.formatted(date: .omitted, time: .shortened))
                }
                if environment.proAccess == .subscriptionRequired {
                    Button("Get DayLedger Pro") { environment.accountSheet = .paywall }
                        .accessibilityIdentifier("getPro")
                }
                Button("Manage subscription") { showingManageSubscription = true }
                    .accessibilityIdentifier("manageSubscription")
            }

            Button("Sign out") { confirmingSignOut = true }
                .disabled(isWorking)
                .accessibilityIdentifier("signOut")

            if !account.isDeveloperAccount {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    if isWorking {
                        ProgressView()
                    } else {
                        Text("Delete account")
                    }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("deleteAccount")
            }
        } header: {
            Text("Account")
        } footer: {
            if !account.isDeveloperAccount {
                Text("Bank, Google and AI keys never leave this iPhone.")
            }
        }
        .manageSubscriptionsSheet(isPresented: $showingManageSubscription)
        .confirmationDialog("Sign out of DayLedger?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Data already on this iPhone stays here. Log in again to keep syncing.")
        }
        .confirmationDialog("Delete your DayLedger account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete account and data", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account, everything synced to it and all DayLedger data on this iPhone. It can't be undone.\n\nYour App Store subscription is not cancelled automatically: cancel it in Settings → Apple ID → Subscriptions.")
        }
        .alert(item: $error) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
        .task { await subscriptions.refreshEntitlement() }
    }

    private var planDescription: String {
        if account.isDeveloperAccount { return "Developer (unlimited)" }
        guard let entitlement = subscriptions.entitlement else { return "Checking…" }
        switch entitlement.status {
        case .trial: return "DayLedger Pro – free trial"
        case .active: return "DayLedger Pro"
        case .gracePeriod: return "DayLedger Pro – payment problem"
        case .billingRetry: return "Payment problem"
        case .expired: return "Expired"
        case .revoked, .refunded: return "Cancelled by Apple"
        case .none: return "No subscription"
        case .unknown: return entitlement.active ? "DayLedger Pro" : "Unknown"
        }
    }

    private var planDate: (label: String, date: Date)? {
        guard !account.isDeveloperAccount, let entitlement = subscriptions.entitlement, let expiresAt = entitlement.expiresAt else { return nil }
        switch entitlement.status {
        case .trial: return ("Trial ends", expiresAt)
        case .active: return (entitlement.autoRenew == false ? "Ends" : "Renews", expiresAt)
        case .gracePeriod: return ("Update payment by", expiresAt)
        case .expired: return ("Ended", expiresAt)
        default: return nil
        }
    }

    private func signOut() {
        isWorking = true
        Task {
            await account.signOut()
            isWorking = false
        }
    }

    private func deleteAccount() {
        isWorking = true
        Task {
            // Deletes the cloud account first (stops if that fails), wipes this device, signs out.
            let report = await DataEraser(environment: environment).eraseAll(deleteCalendars: false)
            isWorking = false
            if let reason = report.abortedReason {
                error = UserFacingError(title: "Account not deleted", message: reason, action: .retry)
            } else {
                onDataErased()
            }
        }
    }
}
