import Foundation

/// Where the DayLedger backend lives. Values come from `Config/*.xcconfig` via Info.plist.
///
/// The anon key is public by design: row-level security protects the data.
public struct SupabaseConfiguration: Sendable, Equatable {
    public let url: URL?
    public let anonKey: String

    public init(url: URL?, anonKey: String) {
        self.url = url
        self.anonKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accepts the raw Info.plist value. Tolerates surrounding whitespace and trailing slashes.
    public init(urlString: String, anonKey: String) {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.init(url: trimmed.isEmpty ? nil : URL(string: trimmed), anonKey: anonKey)
    }

    /// True when both the project URL and the anon key are set. Plain `http` is only accepted for
    /// a local Supabase (`supabase start`) on this machine.
    public var isConfigured: Bool {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty, !anonKey.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1")
    }

    /// The custom URL scheme registered in Info.plist (`CFBundleURLSchemes`).
    public static let callbackScheme = "dayledger"
    /// Email links (confirmation, password reset) and Google sign-in come back here.
    public static let authCallbackURL = "dayledger://auth-callback"

    /// Builds `<project url>/<path>?<query>`, percent-encoding every query value strictly
    /// (PostgREST filters contain `+`, `:` and `,`, which `URLComponents` would leave alone).
    public func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard isConfigured, let base = url else { throw AuthError.notConfigured }
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AuthError.notConfigured
        }
        if !query.isEmpty {
            components.percentEncodedQuery = QueryEncoding.encode(query)
        }
        guard let result = components.url else { throw AuthError.notConfigured }
        return result
    }
}

/// Strict `application/x-www-form-urlencoded`-style encoding for query strings.
enum QueryEncoding {
    /// RFC 3986 unreserved characters, ASCII only.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ items: [URLQueryItem]) -> String {
        items.map { item in
            let name = item.name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? item.name
            guard let value = item.value else { return name }
            return "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)"
        }
        .joined(separator: "&")
    }
}
