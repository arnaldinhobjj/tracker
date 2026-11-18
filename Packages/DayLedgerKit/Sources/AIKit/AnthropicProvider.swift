import Foundation
import Networking

/// Calls the Anthropic Messages API directly with the user's own API key.
public struct AnthropicProvider: AIProvider {
    public let id = "anthropic"
    public let displayName = "Anthropic (Claude)"

    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let defaultModel = "claude-opus-5-5"
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let apiKey: @Sendable () throws -> String?
    private let http: HTTPClient
    public var model: String

    /// `apiKey` is read from the Keychain at call time and never stored anywhere else.
    public init(model: String = AnthropicProvider.defaultModel, http: HTTPClient = URLSessionHTTPClient(),
                apiKey: @escaping @Sendable () throws -> String?) {
        self.model = model
        self.http = http
        self.apiKey = apiKey
    }

    public func proposeEvents(for summary: RoutineSummary, parser: ProposalParser) async throws -> ProposalParseResult {
        let request = try makeRequest(summary: summary)
        let data: Data
        do {
            data = try await http.sendValidated(request)
        } catch let error as NetworkError {
            throw Self.map(error)
        }
        let text = try Self.extractText(from: data)
        return try parser.parse(text)
    }

    func makeRequest(summary: RoutineSummary) throws -> URLRequest {
        guard let key = try apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw AIError.missingAPIKey
        }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 16_000,
            "system": SchedulingPrompt.system,
            "messages": [["role": "user", "content": try SchedulingPrompt.userMessage(for: summary)]],
            "output_config": [
                "effort": "medium",
                "format": ["type": "json_schema", "schema": SchedulingPrompt.responseSchema],
            ],
            // If a safety classifier declines, Anthropic retries on a fallback model in the same call.
            "fallbacks": "default",
        ]
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    static func extractText(from data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(MessageResponse.self, from: data) else {
            throw AIError.invalidResponse("Unexpected response from Anthropic.")
        }
        // Check stop_reason before reading content.
        switch response.stopReason {
        case "refusal": throw AIError.refused
        case "max_tokens": throw AIError.truncated
        default: break
        }
        // Thinking and fallback blocks are skipped; the JSON is in the text block(s).
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw AIError.invalidResponse("Anthropic returned no text.") }
        return text
    }

    static func map(_ error: NetworkError) -> AIError {
        switch error {
        case .unauthorized: return .invalidAPIKey
        case .forbidden(let body): return .providerError(status: 403, message: message(body) ?? "Permission denied for this API key.")
        case .http(429, _): return .rateLimited
        case .http(529, _), .http(503, _): return .overloaded
        case .http(let status, let body): return .providerError(status: status, message: message(body) ?? "Error \(status)")
        case .offline: return .offline
        default: return .network(String(describing: error))
        }
    }

    private static func message(_ body: String?) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        guard let data = body?.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error?.message
    }
}
