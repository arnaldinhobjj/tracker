import Foundation
import Networking

/// DayLedger Pro's AI suggestions, through the `ai-suggest` Edge Function. The function holds
/// DayLedger's Anthropic key, builds the prompt and enforces a daily limit; the app sends only
/// the anonymised `RoutineSummary` (the same JSON "Preview what would be sent" shows) and
/// validates every proposal that comes back with `ProposalParser`.
public struct BackendAIProvider: AIProvider {
    public let id = "dayledger"
    public let displayName = "DayLedger AI (Claude)"

    /// POSTs a JSON body to the function as the signed-in user and returns the response body.
    private let send: @Sendable (Data) async throws -> Data

    public init(send: @escaping @Sendable (Data) async throws -> Data) {
        self.send = send
    }

    struct Response: Decodable {
        let text: String
    }

    public func proposeEvents(for summary: RoutineSummary, parser: ProposalParser) async throws -> ProposalParseResult {
        let body = try JSONEncoder().encode(["summary": summary])
        let data: Data
        do {
            data = try await send(body)
        } catch let error as NetworkError {
            throw Self.map(error)
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw AIError.invalidResponse("Unexpected response from DayLedger's AI service.")
        }
        return try parser.parse(response.text)
    }

    /// Error bodies are `{"error": "<code>", "message": "<text>"}`.
    static func map(_ error: NetworkError) -> AIError {
        struct Body: Decodable {
            let error: String?
            let message: String?
        }
        let body = error.body.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Body.self, from: $0) }
        switch (error.statusCode, body?.error) {
        case (403?, "not_entitled"?): return .notEntitled
        case (429?, _): return .dailyLimitReached(body?.message ?? "You've reached today's limit. Try again tomorrow.")
        case (422?, "refused"?): return .refused
        case (502?, "truncated"?): return .truncated
        case (503?, _): return .overloaded
        case (let status?, _) where status >= 400:
            return .providerError(status: status, message: body?.message ?? "Error \(status)")
        default:
            switch error {
            case .offline: return .offline
            default: return .network(String(describing: error))
            }
        }
    }
}
