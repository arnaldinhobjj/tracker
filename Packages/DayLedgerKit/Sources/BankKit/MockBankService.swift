import Foundation
import SharedModels

/// Deterministic fake bank for SwiftUI previews, UI tests and trying the app without credentials.
public final class MockBankService: BankService, @unchecked Sendable {
    private let lock = NSLock()
    private var connected: [BankConnection]
    private let now: @Sendable () -> Date

    public init(connected: Bool = true, now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
        self.connected = connected
            ? [BankConnection(id: "mock", providerName: "Mock Bank", providerID: "mock", connectedAt: now())]
            : []
    }

    public var isConfigured: Bool { true }

    public func connections() -> [BankConnection] {
        lock.lock(); defer { lock.unlock() }
        return connected
    }

    public func makeAuthorizationRequest() throws -> BankAuthorizationRequest {
        BankAuthorizationRequest(url: URL(string: "https://example.com/mock-bank")!, callbackURLScheme: "dayledger", state: "mock")
    }

    public func completeAuthorization(callbackURL: URL, request: BankAuthorizationRequest) async throws -> BankConnection {
        let connection = BankConnection(id: "mock", providerName: "Mock Bank", providerID: "mock", connectedAt: now())
        lock.withLock { connected = [connection] }
        return connection
    }

    public func fetchTransactions(since: Date, until: Date) async -> BankFetchResult {
        guard !connections().isEmpty else { return BankFetchResult() }
        let transactions = Self.sampleTransactions(for: now())
        return BankFetchResult(transactions: transactions, refreshedAccountIDs: ["mock-current"])
    }

    public func disconnect(connectionID: String) async {
        lock.withLock { connected.removeAll { $0.id == connectionID } }
    }

    public func disconnectAll() async {
        lock.withLock { connected.removeAll() }
    }

    /// A realistic day of spending, relative to `day`.
    public static func sampleTransactions(for day: Date, calendar: Calendar = .current) -> [BankTransaction] {
        let start = calendar.startOfDay(for: day)
        func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: dayOffset, to: start)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: base)!
        }
        func tx(_ id: String, _ merchant: String, _ pence: Int, _ category: SpendCategory, _ date: Date,
                direction: TransactionDirection = .debit, bankCategory: String = "PURCHASE", pending: Bool = false) -> BankTransaction {
            BankTransaction(id: "mock-current:\(id)", accountID: "mock-current", merchant: merchant,
                            rawDescription: merchant.uppercased(), amountMinor: pence, direction: direction,
                            bankCategory: bankCategory, category: category, timestamp: date, hasTime: true, isPending: pending)
        }
        return [
            tx("1", "Costa Coffee", 340, .coffee, at(9, 14)),
            tx("2", "TfL Travel", 280, .transport, at(8, 32)),
            tx("3", "Pret A Manger", 645, .eatingOut, at(12, 41)),
            tx("4", "Tesco Express", 1_287, .groceries, at(18, 5), pending: true),
            tx("5", "PureGym", 2_499, .health, at(7, 0, dayOffset: -1), bankCategory: "DIRECT_DEBIT"),
            tx("6", "Sainsbury's", 4_562, .groceries, at(10, 20, dayOffset: -2)),
        ]
    }
}
