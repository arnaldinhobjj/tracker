import BankKit
import Foundation
import Observation
import SecureStore
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
