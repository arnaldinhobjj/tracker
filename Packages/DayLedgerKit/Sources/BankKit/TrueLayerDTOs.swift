import Foundation

// Wire formats for TrueLayer's Data API v1. Decoded with `.convertFromSnakeCase`.

struct TLResults<T: Decodable>: Decodable {
    let results: [T]
}

struct TLAccount: Decodable, Sendable {
    let accountId: String
    let displayName: String?
    let currency: String?
    let accountType: String?
}

struct TLCard: Decodable, Sendable {
    let accountId: String
    let displayName: String?
    let currency: String?
    let cardType: String?
}

struct TLMe: Decodable, Sendable {
    struct Provider: Decodable, Sendable {
        let displayName: String?
        let providerId: String?
    }
    let provider: Provider?
}

struct TLTransaction: Decodable, Sendable {
    let transactionId: String?
    let timestamp: String
    let description: String
    let transactionType: String?
    let transactionCategory: String?
    let transactionClassification: [String]?
    let merchantName: String?
    let amount: Double
    let currency: String?
    let normalisedProviderTransactionId: String?
    let providerTransactionId: String?
}

extension JSONDecoder {
    static var trueLayer: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
