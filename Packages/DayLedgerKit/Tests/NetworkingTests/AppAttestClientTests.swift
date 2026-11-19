import CryptoKit
import Foundation
@testable import Networking
import XCTest

final class AppAttestClientTests: XCTestCase {
    func testRegistersOnceThenSignsEachBody() async throws {
        let provider = FakeAttestationProvider()
        let registrar = FakeRegistrar()
        let store = MemoryKeyStore()
        let client = AppAttestClient(provider: provider, registrar: registrar, store: store)

        let body = Data(#"{"grant_type":"refresh_token"}"#.utf8)
        let first = await client.headers(for: body)
        let second = await client.headers(for: Data("other".utf8))

        XCTAssertEqual(first[AppAttestHeaders.key], "key-1")
        XCTAssertEqual(second[AppAttestHeaders.key], "key-1")
        XCTAssertEqual(provider.generatedKeys, 1, "One Secure Enclave key")
        XCTAssertEqual(registrar.registrations.map(\.keyID), ["key-1"])
        XCTAssertEqual(store.loadKeyID(), "key-1")
        // Attested with SHA-256 of the challenge; assertions are over SHA-256 of each body.
        XCTAssertEqual(provider.attestedHashes, [Data(SHA256.hash(data: Data("challenge-1".utf8)))])
        XCTAssertEqual(provider.assertedHashes, [Data(SHA256.hash(data: body)), Data(SHA256.hash(data: Data("other".utf8)))])
        XCTAssertEqual(first[AppAttestHeaders.assertion], Data("assertion-1".utf8).base64EncodedString())
    }

    func testConcurrentRequestsShareOneRegistration() async {
        let provider = FakeAttestationProvider()
        let registrar = FakeRegistrar()
        let client = AppAttestClient(provider: provider, registrar: registrar, store: MemoryKeyStore())

        async let a = client.headers(for: Data("a".utf8))
        async let b = client.headers(for: Data("b".utf8))
        let results = await [a, b]

        XCTAssertEqual(results.compactMap { $0[AppAttestHeaders.key] }, ["key-1", "key-1"])
        XCTAssertEqual(provider.generatedKeys, 1)
        XCTAssertEqual(registrar.registrations.count, 1)
    }

    func testUnsupportedDevicesSendNoHeaders() async {
        let provider = FakeAttestationProvider()
        provider.isSupported = false
        let registrar = FakeRegistrar()
        let headers = await AppAttestClient(provider: provider, registrar: registrar, store: MemoryKeyStore()).headers(for: Data())
        XCTAssertTrue(headers.isEmpty)
        XCTAssertTrue(registrar.registrations.isEmpty)
    }

    func testAFailedRegistrationIsRetriedLaterWithTheSameKey() async {
        let provider = FakeAttestationProvider()
        let registrar = FakeRegistrar()
        registrar.failNext = true
        let clock = TestClock()
        let client = AppAttestClient(provider: provider, registrar: registrar, store: MemoryKeyStore(), now: { clock.now })

        let offline = await client.headers(for: Data())
        XCTAssertTrue(offline.isEmpty)
        let tooSoon = await client.headers(for: Data())
        XCTAssertTrue(tooSoon.isEmpty, "No new attempt within the retry delay")
        XCTAssertEqual(registrar.challengesIssued, 1)

        clock.now = clock.now.addingTimeInterval(AppAttestClient.retryDelay + 1)
        let later = await client.headers(for: Data())
        XCTAssertEqual(later[AppAttestHeaders.key], "key-1")
        XCTAssertEqual(provider.generatedKeys, 1, "The key created before the failure is reused")
    }

    func testResetRegistersANewKey() async {
        let provider = FakeAttestationProvider()
        let registrar = FakeRegistrar()
        let store = MemoryKeyStore()
        let client = AppAttestClient(provider: provider, registrar: registrar, store: store)
        _ = await client.headers(for: Data())
        await client.reset()
        let headers = await client.headers(for: Data())
        XCTAssertEqual(headers[AppAttestHeaders.key], "key-2")
        XCTAssertEqual(store.loadKeyID(), "key-2")
    }

    func testAnInvalidKeyIsForgotten() async {
        let provider = FakeAttestationProvider()
        let store = MemoryKeyStore()
        store.saveKeyID("restored-from-another-device")
        provider.invalidKeys = ["restored-from-another-device"]
        let client = AppAttestClient(provider: provider, registrar: FakeRegistrar(), store: store)
        let none = await client.headers(for: Data())
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(store.loadKeyID())
        let fresh = await client.headers(for: Data())
        XCTAssertEqual(fresh[AppAttestHeaders.key], "key-1")
    }

    func testAttestingClientAddsHeadersAndRetriesOnceWhenTheKeyIsRejected() async throws {
        let attester = CountingAttester()
        let http = ScriptedHTTPClient(replies: [
            .init(status: 401, body: #"{"error":"attest_key_unknown","message":"x"}"#),
            .init(status: 200, body: "{}"),
        ])
        let client = AttestingHTTPClient(base: http, attester: attester)
        var request = URLRequest(url: URL(string: "https://example.supabase.co/functions/v1/truelayer-token")!)
        request.httpBody = Data("body".utf8)

        let (_, response) = try await client.send(request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests.map { $0.value(forHTTPHeaderField: AppAttestHeaders.key) }, ["key-a", "key-b"])
        let resets = await attester.resets
        XCTAssertEqual(resets, 1)
    }

    func testOtherErrorsAreNotRetriedAndReportModeHintsReset() async throws {
        let attester = CountingAttester()
        let http = ScriptedHTTPClient(replies: [
            .init(status: 401, body: #"{"error":"attestation_required","message":"x"}"#),
            .init(status: 200, body: "{}", headers: [AppAttestHeaders.status: "register"]),
        ])
        let client = AttestingHTTPClient(base: http, attester: attester)
        let request = URLRequest(url: URL(string: "https://example.supabase.co/functions/v1/ai-suggest")!)

        let (_, required) = try await client.send(request)
        XCTAssertEqual(required.statusCode, 401, "Nothing to retry: this device can't attest")
        var resets = await attester.resets
        XCTAssertEqual(resets, 0)

        _ = try await client.send(request)
        resets = await attester.resets
        XCTAssertEqual(resets, 1, "The next request registers a new key")
        XCTAssertEqual(http.requests.count, 2)
    }
}

// MARK: Fakes

private final class FakeAttestationProvider: AttestationKeyProviding, @unchecked Sendable {
    private let lock = NSLock()
    var isSupported = true
    var invalidKeys: Set<String> = []
    private(set) var generatedKeys = 0
    private(set) var attestedHashes: [Data] = []
    private(set) var assertedHashes: [Data] = []
    private var assertions = 0

    struct InvalidKey: Error {}

    func generateKey() async throws -> String {
        lock.withLock {
            generatedKeys += 1
            return "key-\(generatedKeys)"
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { attestedHashes.append(clientDataHash) }
        return Data("attestation-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            if invalidKeys.contains(keyID) { throw InvalidKey() }
            assertedHashes.append(clientDataHash)
            assertions += 1
            return Data("assertion-\(assertions)".utf8)
        }
    }

    func isInvalidKey(_ error: Error) -> Bool { error is InvalidKey }
}

private final class FakeRegistrar: AppAttestRegistering, @unchecked Sendable {
    private let lock = NSLock()
    var failNext = false
    private(set) var challengesIssued = 0
    private(set) var registrations: [(keyID: String, challenge: String)] = []

    func challenge() async throws -> String {
        // Let a concurrent request reach the client while this one is suspended.
        await Task.yield()
        return try lock.withLock {
            challengesIssued += 1
            if failNext {
                failNext = false
                throw NetworkError.offline
            }
            return "challenge-\(challengesIssued)"
        }
    }

    func register(keyID: String, attestation: Data, challenge: String) async throws {
        lock.withLock { registrations.append((keyID, challenge)) }
    }
}

private final class MemoryKeyStore: AppAttestKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keyID: String?
    func loadKeyID() -> String? { lock.withLock { keyID } }
    func saveKeyID(_ keyID: String?) { lock.withLock { self.keyID = keyID } }
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

private actor CountingAttester: RequestAttesting {
    private(set) var resets = 0
    private let keys = ["key-a", "key-b", "key-c"]

    func headers(for body: Data) -> [String: String] {
        [AppAttestHeaders.key: keys[min(resets, keys.count - 1)], AppAttestHeaders.assertion: "sig"]
    }

    func reset() { resets += 1 }
}

private final class ScriptedHTTPClient: HTTPClient, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(replies: [Reply]) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = lock.withLock {
            requests.append(request)
            return replies.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }
}
