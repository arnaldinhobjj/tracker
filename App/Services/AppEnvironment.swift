import AccountKit
import AIKit
import BankKit
import CalendarKit
import Foundation
import LocationKit
import Observation
import SecureStore
import SharedModels
import SwiftData

/// Dependency container built once at launch. Views receive what they need from here.
@MainActor
@Observable
final class AppEnvironment {
    let configuration: AppConfiguration
    let modelContainer: ModelContainer
    let defaults: UserDefaults
    let secureStore: SecureStoring
    /// End-to-end sync keys (iCloud Keychain in the app, so the user's other devices get them).
    let syncKeyStore: SecureStoring
    let bankService: BankService
    let transactionRepository: TransactionRepository
    let transactionSync: TransactionSyncService
    let widgetPublisher: WidgetPublisher
    let settings: AppSettings
    let visitRepository: VisitRepository
    let googleAuth: GoogleAuthService
    let calendarSync: CalendarSyncService
    let locationLogging: LocationLoggingService
    /// Providers the user can choose from. Anthropic first; add others behind `AIProvider`.
    let aiProviders: [AIProvider]
    /// True when launched by UI tests: in-memory store, mock bank, no Keychain.
    let isUITesting: Bool
    /// DayLedger account (Supabase), subscription and cloud sync.
    let auth: AuthServicing
    let account: AccountController
    let subscriptions: SubscriptionManager
    let cloudSync: CloudSyncService
    /// PostgREST / Edge Functions for the signed-in user. Nil without a backend (not configured,
    /// UI tests, developer account).
    let cloudREST: SupabaseRESTClient?
    /// Sign-in or the paywall, when presented (see `requestPro()`).
    var accountSheet: AccountSheet?

    init(
        configuration: AppConfiguration,
        modelContainer: ModelContainer,
        defaults: UserDefaults,
        secureStore: SecureStoring,
        bankService: BankService,
        isUITesting: Bool,
        syncKeyStore: SecureStoring = InMemorySecureStore(),
        auth injectedAuth: AuthServicing? = nil,
        developerUser: AuthUser? = nil
    ) {
        self.configuration = configuration
        self.modelContainer = modelContainer
        self.defaults = defaults
        self.secureStore = secureStore
        self.syncKeyStore = syncKeyStore
        self.bankService = bankService
        self.isUITesting = isUITesting
        transactionRepository = TransactionRepository(container: modelContainer)
        transactionSync = TransactionSyncService(bank: bankService, repository: transactionRepository, defaults: defaults)
        widgetPublisher = WidgetPublisher(
            // The developer account shows mock data, which must not reach the real widget.
            store: isUITesting || developerUser != nil ? nil : WidgetSnapshotStore(appGroupID: configuration.appGroupID),
            repository: transactionRepository,
            bank: bankService
        )
        settings = AppSettings(defaults: defaults)
        visitRepository = VisitRepository(container: modelContainer)
        googleAuth = GoogleAuthService(configuration: GoogleOAuthConfiguration(clientID: configuration.googleClientID), store: secureStore)
        calendarSync = CalendarSyncService(
            auth: googleAuth,
            client: GoogleCalendarClient(tokens: googleAuth),
            visits: visitRepository,
            transactions: transactionRepository,
            settings: settings,
            defaults: defaults
        )
        locationLogging = LocationLoggingService(
            monitor: LocationMonitor(),
            repository: visitRepository,
            resolver: MapKitPlaceResolver(),
            settings: settings
        )

        let supabase = SupabaseConfiguration(urlString: configuration.supabaseURL, anonKey: configuration.supabaseAnonKey)
        let auth: AuthServicing
        if let injectedAuth {
            auth = injectedAuth
        } else if isUITesting {
            auth = MockAuthService(isConfigured: false)
        } else {
            auth = SupabaseAuthService(configuration: supabase, store: secureStore)
        }
        self.auth = auth
        // No backend calls in UI tests, for the developer account, or without configuration.
        let usesBackend = !isUITesting && developerUser == nil && supabase.isConfigured
        let rest = usesBackend ? SupabaseRESTClient(configuration: supabase, tokens: auth) : nil
        cloudREST = rest
        account = AccountController(auth: auth, developerUser: developerUser)
        subscriptions = SubscriptionManager(
            mode: isUITesting ? .disabled : developerUser != nil ? .alwaysEntitled : .live,
            rest: rest,
            defaults: defaults
        )
        cloudSync = CloudSyncService(rest: rest, keys: SyncKeyManager(store: syncKeyStore), transactions: transactionRepository,
                                     visits: visitRepository, settings: settings, defaults: defaults)

        aiProviders = [
            AnthropicProvider(apiKey: { [secureStore] in
                try secureStore.string(for: SecureStoreKey.aiAPIKey(provider: "anthropic"))
            }),
        ]

        // New transactions can complete a visit's spending, so re-sync the calendar after each bank sync.
        transactionSync.onSynced = { [widgetPublisher, calendarSync, cloudSync] in
            widgetPublisher.publish()
            Task {
                await calendarSync.sync()
                await cloudSync.sync()
            }
        }
        locationLogging.onVisitsChanged = { [calendarSync, cloudSync] in
            await calendarSync.sync()
            await cloudSync.sync()
        }
        wireAccount()
        // Must happen at launch: when iOS relaunches the app for a visit, the location manager
        // has to exist (with monitoring on) to receive it.
        locationLogging.resumeIfEnabled()
    }

    /// Connects the account, the subscription and cloud sync.
    private func wireAccount() {
        let account = self.account
        let subscriptions = self.subscriptions
        let cloudSync = self.cloudSync
        let widgetPublisher = self.widgetPublisher

        cloudSync.currentUserID = {
            account.isDeveloperAccount ? nil : account.user?.id
        }
        cloudSync.canWrite = { subscriptions.isEntitled }
        cloudSync.onSessionExpired = { account.sessionExpired() }
        cloudSync.onDataChanged = { widgetPublisher.publish() }
        subscriptions.onSessionExpired = { account.sessionExpired() }
        subscriptions.onEntitled = {
            Task { await cloudSync.sync() }
        }
        account.onSignedIn = { [weak self] user in
            cloudSync.cancelInFlight()
            Task { @MainActor in
                // A different person signing in on this iPhone must not see, or upload, the
                // previous account's data: wipe it before anything syncs.
                if let self {
                    await DataEraser(environment: self).wipeIfDifferentAccount(newUserID: user.id)
                }
                subscriptions.setUser(user.id)
                await cloudSync.sync()
            }
        }
        account.onSignedOut = {
            cloudSync.cancelInFlight()
            subscriptions.reset()
        }
        if !account.isDeveloperAccount {
            subscriptions.setUser(account.user?.id)
        }
    }

    /// Entry point for BGAppRefreshTask: fetch, store, update the widget, schedule the next one.
    func performBackgroundRefresh() async {
        BackgroundRefresh.schedule()
        _ = await transactionSync.sync()
        widgetPublisher.publish()
        await locationLogging.resolvePending()
        await calendarSync.sync()
        await cloudSync.sync()
    }

    /// Stops long-running listeners before this environment is replaced (developer sign-in/out).
    func shutDown() {
        subscriptions.stopListening()
        locationLogging.monitor.stopMonitoring()
    }

    /// TrueLayer tokens are exchanged by the `truelayer-token` Edge Function, which holds the
    /// client secret. Debug builds with a sandbox secret in `Config/Local.xcconfig` may talk to
    /// TrueLayer directly instead; Release builds can't (no secret, and no direct exchanger).
    static func makeTokenExchanger(configuration: AppConfiguration, trueLayer: TrueLayerConfiguration) -> TrueLayerTokenExchanging {
        #if DEBUG
        if !configuration.trueLayerClientSecret.isEmpty {
            return DirectTrueLayerTokenExchanger(configuration: trueLayer, clientSecret: configuration.trueLayerClientSecret)
        }
        #endif
        let supabase = SupabaseConfiguration(urlString: configuration.supabaseURL, anonKey: configuration.supabaseAnonKey)
        guard let endpoint = try? supabase.endpoint("functions/v1/truelayer-token") else {
            return UnavailableTrueLayerTokenExchanger()
        }
        // The public anon key is enough: bank connections don't need a DayLedger account.
        let anonKey = supabase.anonKey
        return BackendTrueLayerTokenExchanger(endpoint: endpoint, headers: {
            ["apikey": anonKey, "Authorization": "Bearer \(anonKey)"]
        })
    }

    static func makeDefault(processInfo: ProcessInfo = .processInfo) -> AppEnvironment {
        let configuration = AppConfiguration.fromBundle()

        if processInfo.arguments.contains("-UITestMockData") {
            let defaults = UserDefaults(suiteName: "uitests.\(UUID().uuidString)") ?? .standard
            return AppEnvironment(
                configuration: configuration,
                modelContainer: PersistenceController.makeContainer(appGroupID: "", inMemory: true),
                defaults: defaults,
                secureStore: InMemorySecureStore(),
                bankService: MockBankService(connected: true),
                isUITesting: true
            )
        }

        #if DEBUG
        // Debug-only developer login: mock bank, in-memory data, no backend (see DeveloperLogin).
        if DeveloperLogin.isSignedIn() {
            return AppEnvironment(
                configuration: configuration,
                modelContainer: PersistenceController.makeContainer(appGroupID: "", inMemory: true),
                defaults: UserDefaults(suiteName: "app.dayledger.developer") ?? .standard,
                secureStore: InMemorySecureStore(),
                bankService: MockBankService(connected: true),
                isUITesting: false,
                developerUser: DeveloperLogin.user
            )
        }
        #endif

        let defaults = UserDefaults(suiteName: configuration.appGroupID.isEmpty ? nil : configuration.appGroupID) ?? .standard
        let secureStore = KeychainStore()
        let trueLayer = TrueLayerConfiguration(
            clientID: configuration.trueLayerClientID,
            environment: TrueLayerEnvironment(rawValue: configuration.trueLayerEnvironment) ?? .sandbox
        )
        let bank = TrueLayerBankService(
            configuration: trueLayer,
            exchanger: makeTokenExchanger(configuration: configuration, trueLayer: trueLayer),
            secureStore: secureStore,
            connectionStore: BankConnectionStore(defaults: defaults)
        )
        return AppEnvironment(
            configuration: configuration,
            modelContainer: PersistenceController.makeContainer(appGroupID: configuration.appGroupID, inMemory: false),
            defaults: defaults,
            secureStore: secureStore,
            bankService: bank,
            isUITesting: false,
            syncKeyStore: KeychainStore(service: KeychainStore.syncKeyService, synchronizable: true)
        )
    }
}
