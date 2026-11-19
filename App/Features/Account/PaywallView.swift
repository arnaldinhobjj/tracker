import StoreKit
import SwiftUI

/// DayLedger Pro, presented as a sheet to signed-in users without a subscription. Everything that
/// works on the device alone stays free.
struct PaywallView: View {
    let subscriptions: SubscriptionManager
    let account: AccountController
    let configuration: AppConfiguration
    /// Closes the sheet. Nil when not presented as a sheet.
    var onClose: (() -> Void)?

    @State private var isSigningOut = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    if let onClose {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Not now", action: onClose)
                                .accessibilityIdentifier("closePaywall")
                        }
                    }
                }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                benefits
                purchaseArea
                footer
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.28 : 0.14), Color(.systemBackground)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea()
        )
        .task { await subscriptions.loadProduct() }
        .alert(item: Binding(get: { subscriptions.error }, set: { subscriptions.error = $0 })) { error in
            Alert(title: Text(error.title), message: Text(error.message))
        }
        .alert("DayLedger Pro", isPresented: Binding(get: { subscriptions.notice != nil }, set: { if !$0 { subscriptions.notice = nil } })) {
            Button("OK") {}
        } message: {
            Text(subscriptions.notice ?? "")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 80, height: 80)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            Text("DayLedger Pro")
                .font(.largeTitle.bold())
            Text("Your ledger on all your devices, end-to-end encrypted, plus AI suggestions. Everything else stays free.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 16) {
            Benefit(icon: "lock.icloud", title: "Synced and backed up, privately", detail: "Your transactions follow you to a new iPhone, end-to-end encrypted: only your devices can read them, not DayLedger. Visits too, if you choose.")
            Benefit(icon: "sparkles", title: "AI suggestions", detail: "Events proposed from your routine, using an anonymised summary. Nothing is added until you approve it.")
            Benefit(icon: "checkmark.circle", title: "Free without Pro", detail: "Today's spending, widgets, places and your calendar diary work on this iPhone without an account.")
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var purchaseArea: some View {
        VStack(spacing: 12) {
            if let product = subscriptions.product {
                Button {
                    Task { await subscriptions.purchase() }
                } label: {
                    VStack(spacing: 2) {
                        if subscriptions.isPurchasing {
                            ProgressView().tint(.white)
                        } else if let trial = subscriptions.introOfferDescription {
                            Text("Start \(trial) free trial")
                                .font(.headline)
                        } else {
                            Text("Subscribe")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .disabled(subscriptions.isPurchasing || subscriptions.isRestoring)
                .accessibilityIdentifier("startTrial")

                Text(priceLine(for: product))
                    .font(.subheadline.weight(.medium))
                Text("Cancel anytime in Settings → Apple ID → Subscriptions, at least 24 hours before the renewal date. Payment is charged to your Apple ID.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if subscriptions.productLoadFailed {
                VStack(spacing: 8) {
                    Text("Couldn't reach the App Store.")
                        .font(.subheadline.weight(.medium))
                    Button("Try again") { Task { await subscriptions.loadProduct() } }
                }
            } else {
                ProgressView()
                    .frame(minHeight: 52)
            }

            Button {
                Task { await subscriptions.restorePurchases() }
            } label: {
                if subscriptions.isRestoring {
                    ProgressView()
                } else {
                    Text("Restore purchases")
                }
            }
            .font(.subheadline.weight(.medium))
            .disabled(subscriptions.isRestoring || subscriptions.isPurchasing)
            .padding(.top, 4)
            .accessibilityIdentifier("restorePurchases")
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                if let terms = configuration.termsURL {
                    Link("Terms of Use", destination: terms)
                }
                if let privacy = configuration.privacyURL {
                    Link("Privacy Policy", destination: privacy)
                }
            }
            .font(.footnote)

            if let email = account.email {
                Text("Signed in as \(email)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button(isSigningOut ? "Signing out…" : "Sign out") {
                isSigningOut = true
                Task {
                    await account.signOut()
                    isSigningOut = false
                }
            }
            .font(.footnote)
            .disabled(isSigningOut)
            .accessibilityIdentifier("paywallSignOut")
        }
    }

    private func priceLine(for product: Product) -> String {
        let perMonth = "\(product.displayPrice)/month"
        if subscriptions.introOfferDescription != nil {
            return "Then \(perMonth) after the free trial"
        }
        return perMonth
    }
}

private struct Benefit: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
