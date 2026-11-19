import CryptoKit
import DeviceCheck
import Foundation
import os

/// App Attest: lets the DayLedger backend check that a request comes from the genuine app on a
/// real Apple device (`truelayer-token`, `ai-suggest`; see `supabase/functions/_shared/app_attest.ts`).
///
/// The Secure Enclave key is created and attested once (registered through the `app-attest`
/// function); every protected request then carries an assertion: the key's signature over the
/// request body. Where App Attest isn't available (the simulator, some older devices) requests
/// go without one, which the backend accepts until it is switched to "enforce".
public enum AppAttestHeaders {
    public static let key = "X-DayLedger-Attest-Key"
    public static let assertion = "X-DayLedger-Attest-Assertion"
    /// Sent back by the backend when this install should register a new key.
    public static let status = "X-DayLedger-Attest"
}

/// Adds App Attest headers to requests.
public protocol RequestAttesting: Sendable {
    /// Headers proving `body` was sent by this app on a genuine device. Empty when unavailable.
    func headers(for body: Data) async -> [String: String]
    /// The backend doesn't accept the current key: forget it, so the next request registers anew.
    func reset() async
}

/// The Secure Enclave side (`DCAppAttestService`), behind a protocol for tests.
public protocol AttestationKeyProviding: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
    /// The key can't be used any more (e.g. the app was restored onto another device).
    func isInvalidKey(_ error: Error) -> Bool
}

public struct DeviceCheckAttestationProvider: AttestationKeyProviding {
    public init() {}

    public var isSupported: Bool { DCAppAttestService.shared.isSupported }

    public func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }

    public func isInvalidKey(_ error: Error) -> Bool {
        (error as? DCError)?.code == .invalidKey
    }
}

/// Where the registered key ID is kept. It isn't secret: the private key never leaves the Secure
/// Enclave. A reinstall loses both, and the app simply registers again.
public protocol AppAttestKeyStoring: Sendable {
    func loadKeyID() -> String?
    func saveKeyID(_ keyID: String?)
}

public final class UserDefaultsAppAttestKeyStore: AppAttestKeyStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = "appAttest.keyID") {
        self.defaults = defaults
        self.key = key
    }

    public func loadKeyID() -> String? { defaults.string(forKey: key) }

    public func saveKeyID(_ keyID: String?) {
        if let keyID { defaults.set(keyID, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Registers keys with the backend.
public protocol AppAttestRegistering: Sendable {
    func challenge() async throws -> String
    func register(keyID: String, attestation: Data, challenge: String) async throws
}

/// `POST /functions/v1/app-attest`, with the project's anon key (no account needed).
public struct BackendAppAttestRegistrar: AppAttestRegistering {
    private let endpoint: URL
    private let headers: @Sendable () async -> [String: String]
    private let http: HTTPClient

    public init(endpoint: URL, headers: @escaping @Sendable () async -> [String: String], http: HTTPClient = URLSessionHTTPClient()) {
        self.endpoint = endpoint
        self.headers = headers
        self.http = http
    }

    private struct ChallengeResponse: Decodable {
        let challenge: String
    }

    public func challenge() async throws -> String {
        try await http.decode(ChallengeResponse.self, from: request(["action": "challenge"])).challenge
    }

    public func register(keyID: String, attestation: Data, challenge: String) async throws {
        _ = try await http.sendValidated(request([
            "action": "register",
            "keyId": keyID,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge,
        ]))
    }

    private func request(_ body: [String: String]) async throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in await headers() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }
}

/// Creates, registers and uses this install's App Attest key.
public actor AppAttestClient: RequestAttesting {
    /// After a failed registration (offline, backend not set up), wait this long before trying
    /// again, rather than creating a Secure Enclave key on every request.
    public static let retryDelay: TimeInterval = 3_600

    private let provider: AttestationKeyProviding
    private let registrar: AppAttestRegistering
    private let store: AppAttestKeyStoring
    private let now: @Sendable () -> Date
    private let log = Logger(subsystem: "app.dayledger", category: "appattest")

    private var registration: Task<String, Error>?
    /// A key created but not yet registered: attesting can be retried with the same key.
    private var unregisteredKeyID: String?
    private var lastFailure: Date?

    public init(provider: AttestationKeyProviding = DeviceCheckAttestationProvider(), registrar: AppAttestRegistering,
                store: AppAttestKeyStoring, now: @escaping @Sendable () -> Date = Date.init) {
        self.provider = provider
        self.registrar = registrar
        self.store = store
        self.now = now
    }

    public func headers(for body: Data) async -> [String: String] {
        guard provider.isSupported else { return [:] }
        do {
            let keyID = try await registeredKeyID()
            let assertion = try await provider.generateAssertion(keyID, clientDataHash: Self.hash(body))
            return [AppAttestHeaders.key: keyID, AppAttestHeaders.assertion: assertion.base64EncodedString()]
        } catch {
            if provider.isInvalidKey(error) {
                forgetKey()
            }
            log.error("No App Attest assertion: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    public func reset() {
        forgetKey()
        lastFailure = nil
    }

    private func forgetKey() {
        store.saveKeyID(nil)
        unregisteredKeyID = nil
    }

    private func registeredKeyID() async throws -> String {
        if let keyID = store.loadKeyID() { return keyID }
        if let registration { return try await registration.value }
        if let lastFailure, now().timeIntervalSince(lastFailure) < Self.retryDelay {
            throw AppAttestUnavailable()
        }
        let pending = unregisteredKeyID
        let task = Task { [provider, registrar] in
            let keyID: String
            if let pending {
                keyID = pending
            } else {
                keyID = try await provider.generateKey()
            }
            // The task runs on this actor, so this is recorded before the first suspension.
            self.remember(unregistered: keyID)
            let challenge = try await registrar.challenge()
            let attestation = try await provider.attestKey(keyID, clientDataHash: Self.hash(Data(challenge.utf8)))
            try await registrar.register(keyID: keyID, attestation: attestation, challenge: challenge)
            return keyID
        }
        registration = task
        do {
            let keyID = try await task.value
            registration = nil
            unregisteredKeyID = nil
            lastFailure = nil
            store.saveKeyID(keyID)
            return keyID
        } catch {
            registration = nil
            lastFailure = now()
            if provider.isInvalidKey(error) { unregisteredKeyID = nil }
            throw error
        }
    }

    private func remember(unregistered keyID: String) {
        unregisteredKeyID = keyID
    }

    static func hash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

struct AppAttestUnavailable: Error {}

/// Sends requests with App Attest headers for their body. When the backend rejects the key
/// (it was never registered there, or the server's copy was reset), registers a new key and
/// retries once; when it only hints so (in "report" mode), registers on the next request.
public struct AttestingHTTPClient: HTTPClient {
    private let base: HTTPClient
    private let attester: RequestAttesting

    public init(base: HTTPClient = URLSessionHTTPClient(), attester: RequestAttesting) {
        self.base = base
        self.attester = attester
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await base.send(await attested(request))
        if Self.isKeyRejection(status: response.statusCode, body: data) {
            await attester.reset()
            return try await base.send(await attested(request))
        }
        if response.value(forHTTPHeaderField: AppAttestHeaders.status) == "register" {
            await attester.reset()
        }
        return (data, response)
    }

    private func attested(_ request: URLRequest) async -> URLRequest {
        var request = request
        for (name, value) in await attester.headers(for: request.httpBody ?? Data()) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private struct ErrorBody: Decodable {
        let error: String
    }

    static func isKeyRejection(status: Int, body: Data) -> Bool {
        guard status == 401, let code = try? JSONDecoder().decode(ErrorBody.self, from: body).error else { return false }
        return code == "attest_key_unknown" || code == "attestation_invalid"
    }
}
