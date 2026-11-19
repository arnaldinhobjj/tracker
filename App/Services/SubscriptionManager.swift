import AccountKit
import Foundation
import Networking
import Observation
import StoreKit

/// DayLedger Pro with StoreKit 2. Purchases carry `appAccountToken = user id` and are verified by
/// the `verify-subscription` Edge Function; the server's answer is preferred, with StoreKit's own
/// `currentEntitlements` (and the last server answer) as the fallback when offline.
@MainActor
@Observable
final class SubscriptionManager {
    static let productID = "app.dayledger.pro.monthly"

    enum Mode {
        /// StoreKit + the backend.
        case live
        /// Debug developer account: always subscribed, no StoreKit or network.
        case alwaysEntitled
        /// UI tests: never consulted (the gate is skipped).
        case disabled
    }

    private(set) var product: Product?
    private(set) var isEligibleForIntroOffer = true
    private(set) var isLoadingProduct = false
    private(set) var productLoadFailed = false
    private(set) var entitlement: Entitlement?
    /// Nil until the first check for the signed-in user has finished.
    private(set) var hasCheckedEntitlement = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    var error: UserFacingError?
    /// Informational messages, e.g. "waiting for approval".
    var notice: String?

    @ObservationIgnored private let mode: Mode
    @ObservationIgnored private let rest: SupabaseRESTClient?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var userID: UUID?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// The refresh token was rejected while talking to the backend.
    @ObservationIgnored var onSessionExpired: (@MainActor () -> Void)?
    /// The subscription became active (cloud sync hooks in here).
    @ObservationIgnored var onEntitled: (@MainActor () -> Void)?

    init(mode: Mode, rest: SupabaseRESTClient?, defaults: UserDefaults) {
        self.mode = mode
        self.rest = rest
        self.defaults = defaults
        switch mode {
        case .alwaysEntitled:
            entitlement = Entitlement(active: true, status: .active, expiresAt: nil, isTrial: false, productId: Self.productID)
            hasCheckedEntitlement = true
        case .live:
            // Apple: listen from launch so renewals, Ask to Buy and purchases from other devices
            // are never missed. Unfinished transactions are redelivered here on every launch.
            listenForTransactions()
        case .disabled:
            break
        }
    }

    // MARK: State

    /// True when the app should be unlocked.
    var isEntitled: Bool {
        if mode == .alwaysEntitled { return true }
        return entitlement?.isEntitled() ?? false
    }

    var gateEntitlement: AppGate.Entitlement {
        if mode == .alwaysEntitled { return .entitled }
        if isEntitled { return .entitled }
        return hasCheckedEntitlement ? .notEntitled : .unknown
    }

    /// Called when the signed-in account changes.
    func setUser(_ id: UUID?) {
        guard mode == .live, id != userID else { return }
        userID = id
        entitlement = nil
        hasCheckedEntitlement = false
        error = nil
        guard let id else { return }
        // Show the last known answer straight away; the server check below replaces it.
        if let cached = cachedEntitlement(for: id), cached.isEntitled() {
            entitlement = cached
            hasCheckedEntitlement = true
        }
        Task { await refreshEntitlement() }
    }

    // MARK: Entitlement

    /// Asks the server; falls back to the cached answer, then StoreKit, when offline.
    func refreshEntitlement() async {
        guard mode == .live else { return }
        if let refreshTask { return await refreshTask.value }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        guard let userID, let rest else {
            hasCheckedEntitlement = true
            return
        }
        do {
            let server = try await rest.fetchEntitlement()
            if !server.isEntitled(), let local = await currentStoreKitTransaction(for: userID) {
                // Bought on this device but not verified yet (e.g. offline at the time).
                await process(local.transaction, jws: local.jws, userID: userID, rest: rest, reportsErrors: false)
                if isEntitled { return finishCheck() }
            }
            apply(server, for: userID)
        } catch AuthError.sessionExpired {
            onSessionExpired?()
        } catch {
            // Offline or the backend is unavailable.
            if let cached = cachedEntitlement(for: userID), cached.isEntitled() {
                apply(cached, for: userID, cache: false)
            } else if let local = await currentStoreKitTransaction(for: userID) {
                apply(Self.entitlement(from: local.transaction), for: userID, cache: false)
            } else if entitlement == nil {
                entitlement = Entitlement.none
            }
        }
        finishCheck()
    }

    private func finishCheck() {
        hasCheckedEntitlement = true
    }

    private func apply(_ entitlement: Entitlement, for userID: UUID, cache: Bool = true) {
        guard userID == self.userID else { return }
        let wasEntitled = isEntitled
        self.entitlement = entitlement
        hasCheckedEntitlement = true
        if cache { store(entitlement, for: userID) }
        if !wasEntitled && isEntitled { onEntitled?() }
    }

    // MARK: Products

    func loadProduct() async {
        guard mode == .live, product == nil, !isLoadingProduct else { return }
        isLoadingProduct = true
        productLoadFailed = false
        defer { isLoadingProduct = false }
        do {
            product = try await Product.products(for: [Self.productID]).first
            productLoadFailed = product == nil
            if let subscription = product?.subscription {
                isEligibleForIntroOffer = await subscription.isEligibleForIntroOffer
            }
        } catch {
            productLoadFailed = true
        }
    }

    /// The free trial length, e.g. "7-day", when the user can still have it.
    var introOfferDescription: String? {
        guard isEligibleForIntroOffer, let offer = product?.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        return Self.describe(offer.period)
    }

    static func describe(_ period: Product.SubscriptionPeriod) -> String {
        switch period.unit {
        case .day: return "\(period.value)-day"
        case .week: return "\(period.value * 7)-day"
        case .month: return "\(period.value)-month"
        case .year: return "\(period.value)-year"
        @unknown default: return "free"
        }
    }

    // MARK: Purchasing

    func purchase() async {
        guard mode == .live else { return }
        guard let product else {
            error = UserFacingError(title: "Subscription unavailable", message: "Couldn't load DayLedger Pro from the App Store. Check your connection and try again.", action: .retry)
            return
        }
        guard let userID else { return }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase(options: [.appAccountToken(userID)])
            switch result {
            case .success(let verification):
                await handle(verification)
            case .pending:
                notice = "Your purchase is waiting for approval. DayLedger will unlock as soon as it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            self.error = UserFacingError(title: "Purchase failed", message: error.localizedDescription, action: .retry)
        }
    }

    /// "Restore purchases": syncs with the App Store, then re-verifies what this Apple ID owns.
    func restorePurchases() async {
        guard mode == .live, let userID else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
        } catch {
            // Cancelling the Apple ID prompt lands here; still check what we already have.
        }
        var found = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productID == Self.productID else { continue }
            found = true
            if let rest {
                await process(transaction, jws: result.jwsRepresentation, userID: userID, rest: rest)
            }
        }
        if !isEntitled { await refreshEntitlement() }
        if !found && !isEntitled {
            notice = "No DayLedger Pro subscription was found for this Apple ID."
        }
    }

    /// Ends the `Transaction.updates` listener (this manager is being replaced).
    func stopListening() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    private func listenForTransactions() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    /// Sends a verified transaction to the backend, then finishes it. Left unfinished when the
    /// backend can't be reached, so StoreKit hands it over again later.
    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        guard transaction.productID == Self.productID else {
            await transaction.finish()
            return
        }
        guard let userID, let rest else { return }
        await process(transaction, jws: result.jwsRepresentation, userID: userID, rest: rest)
    }

    /// Verifies one StoreKit-verified transaction with `verify-subscription` and applies the result.
    private func process(_ transaction: Transaction, jws: String, userID: UUID, rest: SupabaseRESTClient, reportsErrors: Bool = true) async {
        let ownedByThisAccount = transaction.appAccountToken == nil || transaction.appAccountToken == userID
        do {
            let verified = try await rest.verifySubscription(signedTransaction: jws)
            apply(verified, for: userID)
            await transaction.finish()
        } catch AuthError.sessionExpired {
            onSessionExpired?()
        } catch let networkError as NetworkError where (400..<500).contains(networkError.statusCode ?? 0) && networkError.statusCode != 401 {
            let code = BackendError.code(in: networkError)
            #if DEBUG
            if code == "invalid_signature" {
                // Xcode's local StoreKit configuration signs transactions locally, which the
                // server can't verify. Debug builds trust StoreKit's own check so the paywall
                // works in the Simulator; Release builds never take this path.
                Log.subscriptions.debug("Server rejected a locally signed StoreKit transaction (invalid_signature); using the local entitlement (Debug only).")
                let local = Self.entitlement(from: transaction)
                if local.isEntitled(), ownedByThisAccount {
                    apply(local, for: userID, cache: false)
                }
                await transaction.finish()
                return
            }
            #endif
            // Rejected for good (another account, wrong app, not a subscription): don't retry.
            await transaction.finish()
            if reportsErrors {
                error = BackendError.subscriptionError(code: code, message: BackendError.message(in: networkError))
            }
        } catch {
            // Offline: unlock from StoreKit's own verification until the server has seen it.
            let local = Self.entitlement(from: transaction)
            if local.isEntitled(), ownedByThisAccount {
                apply(local, for: userID, cache: false)
            }
        }
    }

    private func currentStoreKitTransaction(for userID: UUID) async -> (transaction: Transaction, jws: String)? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  transaction.productID == Self.productID,
                  transaction.revocationDate == nil,
                  transaction.appAccountToken == nil || transaction.appAccountToken == userID else { continue }
            if let expiry = transaction.expirationDate, expiry <= Date() { continue }
            return (transaction, result.jwsRepresentation)
        }
        return nil
    }

    static func entitlement(from transaction: Transaction) -> Entitlement {
        let isTrial = transaction.offerType == .introductory
        let revoked = transaction.revocationDate != nil
        let expired = transaction.expirationDate.map { $0 <= Date() } ?? false
        let status: Entitlement.Status = revoked ? .revoked : expired ? .expired : isTrial ? .trial : .active
        return Entitlement(active: !revoked && !expired, status: status, expiresAt: transaction.expirationDate,
                           isTrial: isTrial, productId: transaction.productID)
    }

    // MARK: Cache

    private func cacheKey(_ userID: UUID) -> String { "account.entitlement.\(userID.uuidString)" }

    private func cachedEntitlement(for userID: UUID) -> Entitlement? {
        guard let data = defaults.data(forKey: cacheKey(userID)) else { return nil }
        return try? JSONDecoder().decode(Entitlement.self, from: data)
    }

    private func store(_ entitlement: Entitlement, for userID: UUID) {
        if let data = try? JSONEncoder().encode(entitlement) {
            defaults.set(data, forKey: cacheKey(userID))
        }
    }

    /// Forgets everything about the previous account (sign-out, account deletion).
    func reset() {
        if let userID { defaults.removeObject(forKey: cacheKey(userID)) }
        setUser(nil)
    }
}

/// The Edge Functions' error body: `{"error": "<code>", "message": "<human text>"}`.
enum BackendError {
    private struct Body: Decodable {
        let error: String?
        let message: String?
    }

    private static func body(_ error: NetworkError) -> Body? {
        guard let data = error.body?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Body.self, from: data)
    }

    static func code(in error: NetworkError) -> String? { body(error)?.error }
    static func message(in error: NetworkError) -> String? { body(error)?.message }

    /// What to tell the user when `verify-subscription` refuses a purchase.
    static func subscriptionError(code: String?, message: String?) -> UserFacingError {
        switch code {
        case "account_mismatch":
            return UserFacingError(title: "Subscription belongs to another account",
                                   message: "This App Store subscription was bought for a different DayLedger account. Log in with that account, or subscribe with another Apple ID.")
        case "subscription_in_use":
            return UserFacingError(title: "Subscription already in use",
                                   message: "This App Store subscription is already linked to another DayLedger account.")
        case "bundle_mismatch":
            return UserFacingError(title: "Purchase not for this app", message: "That purchase belongs to a different app.")
        case "not_a_subscription":
            return UserFacingError(title: "Not a subscription", message: "That purchase isn't a DayLedger Pro subscription.")
        case "invalid_signature":
            return UserFacingError(title: "Couldn't verify the purchase", message: "The App Store receipt couldn't be verified. Try \"Restore purchases\".", action: .retry)
        default:
            return UserFacingError(title: "Couldn't verify the purchase",
                                   message: message ?? String(localized: "Please try \"Restore purchases\" in a moment."), action: .retry)
        }
    }
}
