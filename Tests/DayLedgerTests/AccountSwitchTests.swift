import BankKit
import SecureStore
import SharedModels
import XCTest
@testable import DayLedger

/// A different person signing in on the same iPhone must not inherit the previous account's data.
@MainActor
final class AccountSwitchTests: XCTestCase {
    private func makeEnvironment() -> AppEnvironment {
        AppEnvironment(
            configuration: AppConfiguration.fromBundle(),
            modelContainer: PersistenceController.makeContainer(appGroupID: "", inMemory: true),
            defaults: UserDefaults(suiteName: "accountswitch.\(UUID().uuidString)")!,
            secureStore: InMemorySecureStore(),
            bankService: MockBankService(connected: true),
            isUITesting: true
        )
    }

    private func seed(_ environment: AppEnvironment) throws {
        let transactions = MockBankService.sampleTransactions(for: Date())
        try environment.transactionRepository.apply(transactions, refreshedAccountIDs: ["mock-current"])
        try environment.secureStore.set("bank-token", for: SecureStoreKey.trueLayerTokens(connectionID: "mock"))
        try environment.secureStore.set("ai-key", for: SecureStoreKey.aiAPIKey(provider: "anthropic"))
        try environment.secureStore.set("new-session", for: SecureStoreKey.supabaseSession)
    }

    func testFirstAccountOnDeviceKeepsData() async throws {
        let environment = makeEnvironment()
        try seed(environment)

        let wiped = await DataEraser(environment: environment).wipeIfDifferentAccount(newUserID: UUID())

        XCTAssertFalse(wiped)
        XCTAssertFalse(environment.transactionRepository.allStored().isEmpty)
        XCTAssertEqual(try environment.secureStore.string(for: SecureStoreKey.aiAPIKey(provider: "anthropic")), "ai-key")
    }

    func testSameAccountAgainKeepsData() async throws {
        let environment = makeEnvironment()
        let user = UUID()
        await DataEraser(environment: environment).wipeIfDifferentAccount(newUserID: user)
        try seed(environment)

        let wiped = await DataEraser(environment: environment).wipeIfDifferentAccount(newUserID: user)

        XCTAssertFalse(wiped)
        XCTAssertFalse(environment.transactionRepository.allStored().isEmpty)
    }

    func testDifferentAccountWipesPreviousDataButKeepsNewSession() async throws {
        let environment = makeEnvironment()
        await DataEraser(environment: environment).wipeIfDifferentAccount(newUserID: UUID())
        try seed(environment)
        environment.defaults.set(true, forKey: "some.preference")
        let newUser = UUID()

        let wiped = await DataEraser(environment: environment).wipeIfDifferentAccount(newUserID: newUser)

        XCTAssertTrue(wiped)
        XCTAssertTrue(environment.transactionRepository.allStored().isEmpty)
        XCTAssertNil(try environment.secureStore.string(for: SecureStoreKey.trueLayerTokens(connectionID: "mock")))
        XCTAssertNil(try environment.secureStore.string(for: SecureStoreKey.aiAPIKey(provider: "anthropic")))
        XCTAssertEqual(try environment.secureStore.string(for: SecureStoreKey.supabaseSession), "new-session")
        XCTAssertNil(environment.defaults.object(forKey: "some.preference"))
        XCTAssertEqual(environment.defaults.string(forKey: DataEraser.lastAccountKey), newUser.uuidString)
    }
}
