import BankKit
import SharedModels
import XCTest
@testable import DayLedger

@MainActor
final class TodayViewModelTests: XCTestCase {
    private func makeEnvironment(bank: BankService) -> (TodayViewModel, TransactionRepository) {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let repository = TransactionRepository(container: container)
        let defaults = UserDefaults(suiteName: "tests.\(UUID().uuidString)")!
        let sync = TransactionSyncService(bank: bank, repository: repository, defaults: defaults)
        return (TodayViewModel(repository: repository, bank: bank, sync: sync), repository)
    }

    func testRefreshLoadsTodaysTransactionsAndTotal() async {
        let (model, _) = makeEnvironment(bank: MockBankService(connected: true))
        await model.refresh()

        XCTAssertNil(model.error)
        XCTAssertTrue(model.hasConnection)
        // Mock day: Costa £3.40 + TfL £2.80 + Pret £6.45 + Tesco £12.87 (pending) = £25.52
        XCTAssertEqual(model.totalSpentMinor, 2_552)
        XCTAssertEqual(model.transactions.count, 4)
        XCTAssertEqual(model.transactions.map(\.merchant).first, "Tesco Express") // newest first
    }

    func testNoConnectionShowsEmptyState() async {
        let (model, _) = makeEnvironment(bank: MockBankService(connected: false))
        await model.onAppear()
        XCTAssertFalse(model.hasConnection)
        XCTAssertEqual(model.totalSpentMinor, 0)
    }

    func testCachedDataSurvivesOfflineRefresh() async throws {
        let (model, repository) = makeEnvironment(bank: OfflineBank())
        try repository.apply(MockBankService.sampleTransactions(for: Date()), refreshedAccountIDs: [])
        await model.refresh()

        XCTAssertEqual(model.error?.title, "You're offline")
        XCTAssertEqual(model.totalSpentMinor, 2_552, "Cached transactions are still shown")
    }

    func testPendingTransactionsAreReplacedWhenTheySettle() throws {
        let container = PersistenceController.makeContainer(appGroupID: "", inMemory: true)
        let repository = TransactionRepository(container: container)
        let now = Date()
        let pending = BankTransaction(id: "a:pending:1", accountID: "a", merchant: "Tesco", rawDescription: "TESCO", amountMinor: 500,
                                      direction: .debit, bankCategory: "PURCHASE", category: .groceries, timestamp: now, hasTime: true, isPending: true)
        try repository.apply([pending], refreshedAccountIDs: ["a"])

        var settled = pending
        settled.id = "a:1"
        settled.isPending = false
        try repository.apply([settled], refreshedAccountIDs: ["a"])

        let stored = repository.transactions(on: now)
        XCTAssertEqual(stored.map(\.id), ["a:1"])
    }
}

/// A connected bank whose every fetch fails because the device is offline.
private final class OfflineBank: BankService, @unchecked Sendable {
    var isConfigured: Bool { true }
    func connections() -> [BankConnection] { [BankConnection(id: "c", providerName: "Bank", connectedAt: Date())] }
    func makeAuthorizationRequest() throws -> BankAuthorizationRequest { throw BankError.notConfigured }
    func completeAuthorization(callbackURL: URL, request: BankAuthorizationRequest) async throws -> BankConnection { throw BankError.notConfigured }
    func fetchTransactions(since: Date, until: Date) async -> BankFetchResult {
        BankFetchResult(failures: [BankConnectionFailure(connection: connections()[0], error: .network(.offline))])
    }
    func disconnect(connectionID: String) async {}
    func disconnectAll() async {}
}
