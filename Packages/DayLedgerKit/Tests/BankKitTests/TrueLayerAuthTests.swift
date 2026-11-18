import XCTest
@testable import BankKit
import Networking
import SecureStore

final class TrueLayerAuthTests: XCTestCase {
    let configuration = TrueLayerConfiguration(clientID: "sandbox-dayledger-123")

    func testAuthorizationURLContainsRequiredParameters() throws {
        let url = configuration.authorizationURL(state: "xyz")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(url.host, "auth.truelayer-sandbox.com")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), "sandbox-dayledger-123")
        XCTAssertEqual(value("state"), "xyz")
        XCTAssertEqual(value("redirect_uri"), "dayledger://truelayer-callback")
        XCTAssertTrue(value("scope")?.contains("offline_access") == true)
        XCTAssertTrue(value("providers")?.contains("uk-cs-mock") == true)
    }

    func testCallbackValidation() throws {
        let good = URL(string: "dayledger://truelayer-callback?code=abc&state=xyz")!
        XCTAssertEqual(try configuration.authorizationCode(from: good, expectedState: "xyz"), "abc")

        let wrongState = URL(string: "dayledger://truelayer-callback?code=abc&state=evil")!
        XCTAssertThrowsError(try configuration.authorizationCode(from: wrongState, expectedState: "xyz")) {
            XCTAssertEqual($0 as? BankError, .stateMismatch)
        }

        let denied = URL(string: "dayledger://truelayer-callback?error=access_denied&state=xyz")!
        XCTAssertThrowsError(try configuration.authorizationCode(from: denied, expectedState: "xyz")) {
            XCTAssertEqual($0 as? BankError, .authorizationDenied("access_denied"))
        }
    }

    func testExpiredRefreshTokenRequiresReconnect() async {
        let http = StubHTTPClient()
        http.on("/connect/token", status: 400, body: #"{"error":"invalid_grant"}"#)
        let exchanger = DirectTrueLayerTokenExchanger(configuration: configuration, clientSecret: "s", http: http)
        do {
            _ = try await exchanger.refresh(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantPast))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? BankError, .reconnectRequired(connectionName: nil))
        }
    }

    func testFetchRefreshesExpiredTokenAndMarksConnection() async throws {
        let http = StubHTTPClient()
        http.on("/connect/token", body: #"{"access_token":"new","expires_in":3600,"refresh_token":"r2"}"#)
        http.on("/data/v1/accounts", body: #"{"results":[{"account_id":"acc1","display_name":"Current"}]}"#)
        http.on("/data/v1/cards", status: 501, body: #"{"error":"endpoint_not_supported"}"#)
        http.on("/acc1/transactions", body: #"{"results":[{"transaction_id":"t1","timestamp":"2024-03-06T09:14:00Z","description":"COSTA","transaction_type":"DEBIT","transaction_category":"PURCHASE","amount":-3.4,"currency":"GBP"}]}"#)
        http.on("/acc1/transactions/pending", body: #"{"results":[]}"#)

        let secure = InMemorySecureStore()
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let connections = BankConnectionStore(defaults: defaults)
        connections.upsert(BankConnection(id: "c1", providerName: "Mock", connectedAt: Date()))
        try secure.setValue(OAuthTokens(accessToken: "old", refreshToken: "r1", expiresAt: .distantPast),
                            for: SecureStoreKey.trueLayerTokens(connectionID: "c1"))

        let service = TrueLayerBankService(
            configuration: configuration,
            exchanger: DirectTrueLayerTokenExchanger(configuration: configuration, clientSecret: "s", http: http),
            secureStore: secure, connectionStore: connections, http: http)

        let result = await service.fetchTransactions(since: .distantPast, until: Date())
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertEqual(result.transactions.map(\.id), ["acc1:t1"])
        XCTAssertEqual(result.refreshedAccountIDs, ["acc1"])

        let stored = try secure.value(OAuthTokens.self, for: SecureStoreKey.trueLayerTokens(connectionID: "c1"))
        XCTAssertEqual(stored?.accessToken, "new")
        XCTAssertEqual(stored?.refreshToken, "r2")
        XCTAssertEqual(http.requests.first(where: { $0.url?.path == "/data/v1/accounts" })?.value(forHTTPHeaderField: "Authorization"), "Bearer new")
    }

    func testForbiddenMarksConnectionForReconnect() async throws {
        let http = StubHTTPClient()
        http.on("/data/v1/accounts", status: 403, body: #"{"error":"sca_exceeded"}"#)
        let secure = InMemorySecureStore()
        let connections = BankConnectionStore(defaults: UserDefaults(suiteName: "test.\(UUID().uuidString)")!)
        connections.upsert(BankConnection(id: "c1", providerName: "Monzo", connectedAt: Date()))
        try secure.setValue(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture),
                            for: SecureStoreKey.trueLayerTokens(connectionID: "c1"))
        let service = TrueLayerBankService(
            configuration: configuration,
            exchanger: DirectTrueLayerTokenExchanger(configuration: configuration, clientSecret: "s", http: http),
            secureStore: secure, connectionStore: connections, http: http)

        let result = await service.fetchTransactions(since: .distantPast, until: Date())
        XCTAssertEqual(result.failures.first?.error, .reconnectRequired(connectionName: "Monzo"))
        XCTAssertEqual(connections.all().first?.needsReconnect, true)
    }
}
