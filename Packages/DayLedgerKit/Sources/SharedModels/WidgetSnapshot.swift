import Foundation

/// The small, pre-computed payload the widget reads from the App Group container.
/// The widget never touches the database or the network.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var merchant: String
        public var amountMinor: Int
        public var currency: String
        public var isCredit: Bool
        public var time: Date?
        public var symbolName: String
        public var isPending: Bool

        public init(id: String, merchant: String, amountMinor: Int, currency: String, isCredit: Bool, time: Date?, symbolName: String, isPending: Bool) {
            self.id = id
            self.merchant = merchant
            self.amountMinor = amountMinor
            self.currency = currency
            self.isCredit = isCredit
            self.time = time
            self.symbolName = symbolName
            self.isPending = isPending
        }

        public var formattedAmount: String {
            let base = MoneyFormatting.string(minorUnits: amountMinor, currencyCode: currency)
            return isCredit ? "+\(base)" : base
        }
    }

    /// Start of the day the totals refer to.
    public var day: Date
    public var generatedAt: Date
    public var totalSpentMinor: Int
    public var currency: String
    public var transactionCount: Int
    /// Newest first, at most `maxItems`.
    public var latest: [Item]
    public var hasBankConnection: Bool
    public var needsReconnect: Bool

    public static let maxItems = 3

    public init(day: Date, generatedAt: Date, totalSpentMinor: Int, currency: String = "GBP", transactionCount: Int,
                latest: [Item], hasBankConnection: Bool, needsReconnect: Bool) {
        self.day = day
        self.generatedAt = generatedAt
        self.totalSpentMinor = totalSpentMinor
        self.currency = currency
        self.transactionCount = transactionCount
        self.latest = latest
        self.hasBankConnection = hasBankConnection
        self.needsReconnect = needsReconnect
    }

    /// Builds a snapshot for the day containing `now`.
    public static func make(from transactions: [BankTransaction], now: Date, calendar: Calendar = .current,
                            hasBankConnection: Bool, needsReconnect: Bool) -> WidgetSnapshot {
        let today = SpendingCalculator.transactions(transactions, on: now, calendar: calendar)
        let items = today.prefix(maxItems).map { transaction in
            Item(
                id: transaction.id,
                merchant: transaction.merchant,
                amountMinor: transaction.amountMinor,
                currency: transaction.currency,
                isCredit: transaction.direction == .credit,
                time: transaction.hasTime ? transaction.timestamp : nil,
                symbolName: transaction.category.symbolName,
                isPending: transaction.isPending
            )
        }
        return WidgetSnapshot(
            day: calendar.startOfDay(for: now),
            generatedAt: now,
            totalSpentMinor: SpendingCalculator.netSpendMinor(today),
            currency: today.first?.currency ?? "GBP",
            transactionCount: today.count,
            latest: Array(items),
            hasBankConnection: hasBankConnection,
            needsReconnect: needsReconnect
        )
    }

    /// What the widget should show at `date`. After midnight a stale snapshot shows an empty day
    /// rather than yesterday's spending.
    public func displayed(at date: Date, calendar: Calendar = .current) -> WidgetSnapshot {
        guard !calendar.isDate(date, inSameDayAs: day) else { return self }
        var empty = self
        empty.day = calendar.startOfDay(for: date)
        empty.totalSpentMinor = 0
        empty.transactionCount = 0
        empty.latest = []
        return empty
    }

    /// Ignores `generatedAt`, so rewriting identical data doesn't trigger a widget reload.
    public func hasSameContent(as other: WidgetSnapshot) -> Bool {
        var a = self, b = other
        a.generatedAt = .distantPast
        b.generatedAt = .distantPast
        return a == b
    }

    public static let placeholder = WidgetSnapshot(
        day: Calendar.current.startOfDay(for: Date()),
        generatedAt: Date(),
        totalSpentMinor: 2_552,
        transactionCount: 4,
        latest: [
            Item(id: "1", merchant: "Tesco Express", amountMinor: 1_287, currency: "GBP", isCredit: false, time: Date(), symbolName: "cart", isPending: true),
            Item(id: "2", merchant: "Pret A Manger", amountMinor: 645, currency: "GBP", isCredit: false, time: Date(), symbolName: "fork.knife", isPending: false),
            Item(id: "3", merchant: "Costa Coffee", amountMinor: 340, currency: "GBP", isCredit: false, time: Date(), symbolName: "cup.and.saucer", isPending: false),
        ],
        hasBankConnection: true,
        needsReconnect: false
    )
}

/// Reads and writes the snapshot as JSON in the shared App Group container.
public struct WidgetSnapshotStore: Sendable {
    public static let widgetKind = "DayLedgerSpendWidget"
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `nil` when the App Group isn't available (e.g. unsigned simulator builds).
    public init?(appGroupID: String, fileManager: FileManager = .default) {
        guard !appGroupID.isEmpty,
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        self.init(fileURL: container.appendingPathComponent("widget-snapshot.json"))
    }

    public func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public func save(_ snapshot: WidgetSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        // Readable after first unlock so the lock screen widget can show it.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
