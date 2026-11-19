import AccountKit
import AIKit
import BankKit
import CalendarKit
import Foundation
import LocationKit
import Networking
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
    /// Apple Calendar (EventKit); its permission is requested from Settings.
    let appleCalendar: EventKitCalendarDestination
    let calendarSync: CalendarSyncService
    let locationLogging: LocationLoggingService
    /// AI suggestion providers (DayLedger Pro, through the backend).
    let aiProviders: [AIProvider]
    /// True when launched by UI tests: in-memory store, mock bank, no Keychain.
    let isUITesting: Bool
    /// DayLedger account (Supabase), subscription and cloud sync.
    let auth: AuthServicing
    let account: AccountController
    let subscriptions: SubscriptionManager
    let cloudSync: CloudSyncService
    /// Runs every sync in a fixed order and merges overlapping requests.
    let coordinator: SyncCoordinator
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
        developerUser: AuthUser? = nil,
        attester: RequestAttesting? = nil
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
        // UI tests and the developer account never touch the real calendars.
        appleCalendar = EventKitCalendarDestination(
            store: isUITesting || developerUser != nil ? InMemoryEventStore() as EventStoring : SystemEventStore()
        )
        calendarSync = CalendarSyncService(
            google: GoogleCalendarDestination(auth: googleAuth, client: GoogleCalendarClient(tokens: googleAuth)),
            apple: appleCalendar,
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

        // DayLedger Pro's suggestions run on the backend with DayLedger's own key.
        aiProviders = [
            BackendAIProvider(send: { [rest, attester] body in
                guard let rest else { throw AIError.notEntitled }
                return try await rest.invokeFunction("ai-suggest", body: body, timeout: BackendAIProvider.requestTimeout,
                                                     attester: attester)
            }),
        ]
        // Earlier versions asked users for their own Anthropic API key. It's no longer used:
        // remove it from the Keychain.
        try? secureStore.remove(SecureStoreKey.aiAPIKey(provider: "anthropic"))

        coordinator = SyncCoordinator(perform: { [transactionSync, locationLogging, widgetPublisher, calendarSync, subscriptions, cloudSync, account] step in
            switch step {
            case .bank: _ = await transactionSync.sync()
            case .places: await locationLogging.resolvePending()
            case .widget: widgetPublisher.publish()
            case .calendar: await calendarSync.sync()
            case .entitlement: if account.isSignedIn { await subscriptions.refreshEntitlement() }
            case .cloud: await cloudSync.sync()
            default: break
            }
        })

        // New transactions can complete a visit's spending: after any bank sync (pull-to-refresh,
        // connecting a bank, or the coordinator's own bank step) update the widget, calendar and
        // cloud. Inside a coordinator pass these steps are still to come, so nothing runs twice.
        transactionSync.onSynced = { [coordinator] in
            coordinator.schedule([.widget, .calendar, .cloud])
        }
        locationLogging.onVisitsChanged = { [coordinator] in
            await coordinator.request([.calendar, .cloud])
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
        let coordinator = self.coordinator
        subscriptions.onEntitled = {
            coordinator.schedule(.cloud)
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
                await coordinator.request(.cloud)
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

    /// The app became active: retry place lookups, update the widget (also covers midnight while
    /// the app was closed), the calendar, the subscription and the cloud copy. The bank itself is
    /// refreshed by the Today screen when its data is stale, which also feeds the coordinator.
    func appDidBecomeActive() async {
        await coordinator.request([.places, .widget, .calendar, .entitlement, .cloud])
    }

    /// Entry point for BGAppRefreshTask: everything, then schedule the next one.
    func performBackgroundRefresh() async {
        BackgroundRefresh.schedule()
        await coordinator.request(.all)
    }

    /// Entry point for the BGProcessingTask (longer, needs network): the full pipeline, so a first
    /// cloud sync or a calendar backfill can finish without the app open.
    func performBackgroundProcessing() async {
        BackgroundRefresh.scheduleProcessing()
        await coordinator.request(.all)
    }

    /// Stops long-running listeners before this environment is replaced (developer sign-in/out).
    func shutDown() {
        subscriptions.stopListening()
        locationLogging.monitor.stopMonitoring()
    }

    /// TrueLayer tokens are exchanged by the `truelayer-token` Edge Function, which holds the
    /// client secret. Debug builds with a sandbox secret in `Config/Local.xcconfig` may talk to
    /// TrueLayer directly instead; Release builds can't (no secret, and no direct exchanger).
    /// App Attest for the functions that spend DayLedger's money or hold its secrets. Nil without
    /// a backend. Devices that can't attest (the simulator) just send no assertion.
    static func makeAttester(configuration: AppConfiguration, defaults: UserDefaults) -> RequestAttesting? {
        let supabase = SupabaseConfiguration(urlString: configuration.supabaseURL, anonKey: configuration.supabaseAnonKey)
        guard let endpoint = try? supabase.endpoint("functions/v1/app-attest") else { return nil }
        let anonKey = supabase.anonKey
        return AppAttestClient(
            registrar: BackendAppAttestRegistrar(endpoint: endpoint, headers: {
                ["apikey": anonKey, "Authorization": "Bearer \(anonKey)"]
            }),
            store: UserDefaultsAppAttestKeyStore(defaults: defaults)
        )
    }

    static func makeTokenExchanger(configuration: AppConfiguration, trueLayer: TrueLayerConfiguration,
                                   attester: RequestAttesting? = nil) -> TrueLayerTokenExchanging {
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
        }, http: attester.map { AttestingHTTPClient(attester: $0) as HTTPClient } ?? URLSessionHTTPClient())
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
        let store = PersistenceController.open(appGroupID: configuration.appGroupID, inMemory: false)
        if store.result != .opened {
            // The old store was unreadable (kept aside, not deleted): fetch the bank's recent
            // history and the whole cloud copy again.
            PersistenceController.resetSyncBookkeeping(defaults)
        }
        let secureStore = KeychainStore()
        let attester = makeAttester(configuration: configuration, defaults: defaults)
        let trueLayer = TrueLayerConfiguration(
            clientID: configuration.trueLayerClientID,
            environment: TrueLayerEnvironment(rawValue: configuration.trueLayerEnvironment) ?? .sandbox
        )
        let bank = TrueLayerBankService(
            configuration: trueLayer,
            exchanger: makeTokenExchanger(configuration: configuration, trueLayer: trueLayer, attester: attester),
            secureStore: secureStore,
            connectionStore: BankConnectionStore(defaults: defaults)
        )
        return AppEnvironment(
            configuration: configuration,
            modelContainer: store.container,
            defaults: defaults,
            secureStore: secureStore,
            bankService: bank,
            isUITesting: false,
            syncKeyStore: KeychainStore(service: KeychainStore.syncKeyService, synchronizable: true),
            attester: attester
        )
    }
}
