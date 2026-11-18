import Foundation

/// Transport-level errors, independent of any particular API.
public enum NetworkError: Error, Equatable, Sendable {
    /// No connection (airplane mode, no signal, etc.).
    case offline
    case timedOut
    case cancelled
    /// HTTP 401. Usually means the access token expired or was revoked.
    case unauthorized(body: String?)
    /// HTTP 403.
    case forbidden(body: String?)
    /// Any other non-2xx status.
    case http(status: Int, body: String?)
    case invalidResponse
    case decoding(String)
    case transport(String)

    public init(_ error: URLError) {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            self = .offline
        case .timedOut:
            self = .timedOut
        case .cancelled:
            self = .cancelled
        default:
            self = .transport(error.localizedDescription)
        }
    }

    /// The response body for HTTP errors, if any.
    public var body: String? {
        switch self {
        case .unauthorized(let body), .forbidden(let body), .http(_, let body): return body
        default: return nil
        }
    }

    public var statusCode: Int? {
        switch self {
        case .unauthorized: return 401
        case .forbidden: return 403
        case .http(let status, _): return status
        default: return nil
        }
    }
}
