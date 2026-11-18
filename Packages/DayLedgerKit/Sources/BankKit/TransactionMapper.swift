import Foundation
import SharedModels

enum TransactionMapper {
    static func map(_ dto: TLTransaction, accountID: String, isPending: Bool) -> BankTransaction? {
        guard let parsed = TrueLayerDateParser.parse(dto.timestamp) else { return nil }

        let direction: TransactionDirection
        switch dto.transactionType?.uppercased() {
        case "DEBIT": direction = .debit
        case "CREDIT": direction = .credit
        default: direction = dto.amount < 0 ? .debit : .credit
        }

        let merchant: String = {
            if let name = dto.merchantName?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
            return MerchantNameNormaliser.displayName(from: dto.description)
        }()
        let bankCategory = dto.transactionCategory?.uppercased() ?? "UNKNOWN"
        let providerID = dto.transactionId
            ?? dto.normalisedProviderTransactionId
            ?? dto.providerTransactionId
            ?? "\(dto.timestamp)|\(dto.amount)|\(dto.description)"

        return BankTransaction(
            id: "\(accountID):\(isPending ? "pending:" : "")\(providerID)",
            accountID: accountID,
            merchant: merchant,
            rawDescription: dto.description,
            amountMinor: MoneyFormatting.minorUnits(fromMajor: dto.amount),
            currency: dto.currency ?? "GBP",
            direction: direction,
            bankCategory: bankCategory,
            category: TransactionCategoriser.categorise(
                bankCategory: bankCategory,
                classification: dto.transactionClassification ?? [],
                merchant: merchant,
                direction: direction
            ),
            timestamp: parsed.date,
            hasTime: parsed.hasTime,
            isPending: isPending
        )
    }
}
