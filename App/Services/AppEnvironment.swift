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

    init(
        configuration: AppConfiguration,
        modelContainer: ModelContainer,
        defaults: UserDefaults,
        secureStore: SecureStoring,
        bankService: BankService,
        isUITesting: Bool
    ) {
        self.configuration = configuration
        self.modelContainer = modelContainer
        self.defaults = defaults
        self.secureStore = secureStore
        self.bankService = bankService
        self.isUITesting = isUITesting
        transactionRepository = TransactionRepository(container: modelContainer)
        transactionSync = TransactionSyncService(bank: bankService, repository: transactionRepository, defaults: defaults)
        widgetPublisher = WidgetPublisher(
            store: isUITesting ? nil : WidgetSnapshotStore(appGroupID: configuration.appGroupID),
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

        aiProviders = [
            AnthropicProvider(apiKey: { [secureStore] in
                try secureStore.string(for: SecureStoreKey.aiAPIKey(provider: "anthropic"))
            }),
        ]

        // New transactions can complete a visit's spending, so re-sync the calendar after each bank sync.
        transactionSync.onSynced = { [widgetPublisher, calendarSync] in
            widgetPublisher.publish()
            Task { await calendarSync.sync() }
        }
        locationLogging.onVisitsChanged = { [calendarSync] in
            await calendarSync.sync()
        }
        // Must happen at launch: when iOS relaunches the app for a visit, the location manager
        // has to exist (with monitoring on) to receive it.
        locationLogging.resumeIfEnabled()
    }

    /// Entry point for BGAppRefreshTask: fetch, store, update the widget, schedule the next one.
    func performBackgroundRefresh() async {
        BackgroundRefresh.schedule()
        _ = await transactionSync.sync()
        widgetPublisher.publish()
        await locationLogging.resolvePending()
        await calendarSync.sync()
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

        let defaults = UserDefaults(suiteName: configuration.appGroupID.isEmpty ? nil : configuration.appGroupID) ?? .standard
        let secureStore = KeychainStore()
        let trueLayer = TrueLayerConfiguration(
            clientID: configuration.trueLayerClientID,
            environment: TrueLayerEnvironment(rawValue: configuration.trueLayerEnvironment) ?? .sandbox
        )
        let bank = TrueLayerBankService(
            configuration: trueLayer,
            exchanger: DirectTrueLayerTokenExchanger(configuration: trueLayer, clientSecret: configuration.trueLayerClientSecret),
            secureStore: secureStore,
            connectionStore: BankConnectionStore(defaults: defaults)
        )
        return AppEnvironment(
            configuration: configuration,
            modelContainer: PersistenceController.makeContainer(appGroupID: configuration.appGroupID, inMemory: false),
            defaults: defaults,
            secureStore: secureStore,
            bankService: bank,
            isUITesting: false
        )
    }
}
