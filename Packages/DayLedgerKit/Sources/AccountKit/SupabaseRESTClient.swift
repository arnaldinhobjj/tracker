import Foundation
import Networking

/// Where a pull stopped: the last row's server `updated_at` and, for tables with an `id`, its id.
/// Rows written in one request share `updated_at`, so the id breaks ties and no row is skipped
/// when a page ends in the middle of such a group.
public struct SyncCursor: Codable, Equatable, Sendable {
    public var updatedAt: String
    public var id: String?

    public init(updatedAt: String, id: String?) {
        self.updatedAt = updatedAt
        self.id = id
    }
}

/// PostgREST and Edge Function calls for the signed-in user. Every call carries the anon key and
/// the user's access token; a 401 triggers one token refresh and one retry.
public final class SupabaseRESTClient: @unchecked Sendable {
    public static let pageSize = 500
    public static let maxBatchSize = 500

    public let configuration: SupabaseConfiguration
    private let tokens: AccessTokenProviding
    private let http: HTTPClient

    public init(configuration: SupabaseConfiguration, tokens: AccessTokenProviding, http: HTTPClient = URLSessionHTTPClient()) {
        self.configuration = configuration
        self.tokens = tokens
        self.http = http
    }

    // MARK: PostgREST

    /// Upserts rows in batches of at most 500:
    /// `POST /rest/v1/<table>?on_conflict=<columns>` with `Prefer: resolution=merge-duplicates,return=minimal`.
    public func upsert<Row: Encodable>(_ rows: [Row], into table: String, onConflict: String) async throws {
        guard !rows.isEmpty else { return }
        let url = try configuration.endpoint("rest/v1/\(table)", query: [URLQueryItem(name: "on_conflict", value: onConflict)])
        let encoder = JSONEncoder()
        var start = 0
        while start < rows.count {
            let end = min(start + Self.maxBatchSize, rows.count)
            let body = try encoder.encode(Array(rows[start..<end]))
            _ = try await authorised(url: url, method: "POST", body: body, headers: [
                "Prefer": "resolution=merge-duplicates,return=minimal",
            ])
            start = end
        }
    }

    /// One page of rows changed after `cursor`, oldest first:
    /// `GET /rest/v1/<table>?select=*&updated_at=gt.<cursor>&order=updated_at.asc&limit=500`
    /// (with `id` as a tie-breaker when the cursor has one).
    public func fetchPage<Row: SyncRow>(_ type: Row.Type, from table: String, after cursor: SyncCursor?,
                                        hasIDColumn: Bool = true, limit: Int = SupabaseRESTClient.pageSize) async throws -> [Row] {
        var query = [URLQueryItem(name: "select", value: "*")]
        if let cursor {
            if hasIDColumn, let id = cursor.id {
                let ts = Self.quoted(cursor.updatedAt)
                query.append(URLQueryItem(name: "or", value: "(updated_at.gt.\(ts),and(updated_at.eq.\(ts),id.gt.\(Self.quoted(id))))"))
            } else {
                query.append(URLQueryItem(name: "updated_at", value: "gt.\(cursor.updatedAt)"))
            }
        }
        query.append(URLQueryItem(name: "order", value: hasIDColumn ? "updated_at.asc,id.asc" : "updated_at.asc"))
        query.append(URLQueryItem(name: "limit", value: String(limit)))
        let url = try configuration.endpoint("rest/v1/\(table)", query: query)
        let data = try await authorised(url: url, method: "GET", body: nil)
        do {
            return try JSONDecoder().decode([Row].self, from: data)
        } catch {
            throw NetworkError.decoding(String(describing: error))
        }
    }

    /// Every row changed after `cursor`, page by page until a page comes back short.
    /// Returns the rows and the cursor to store for next time.
    public func fetchChanges<Row: SyncRow>(_ type: Row.Type, from table: String, after cursor: SyncCursor?,
                                           hasIDColumn: Bool = true, pageSize: Int = SupabaseRESTClient.pageSize) async throws -> (rows: [Row], cursor: SyncCursor?) {
        var all: [Row] = []
        var position = cursor
        while true {
            let page = try await fetchPage(type, from: table, after: position, hasIDColumn: hasIDColumn, limit: pageSize)
            all.append(contentsOf: page)
            if let last = page.last, let updatedAt = last.updatedAt {
                position = SyncCursor(updatedAt: updatedAt, id: hasIDColumn ? last.cursorID : nil)
            }
            if page.count < pageSize { break }
            // A full page without a usable cursor would loop forever.
            if page.last?.updatedAt == nil { break }
        }
        return (all, position)
    }

    /// `POST /rest/v1/rpc/<name>`.
    public func rpc<Result: Decodable>(_ name: String, params: [String: String] = [:], returning type: Result.Type) async throws -> Result {
        let url = try configuration.endpoint("rest/v1/rpc/\(name)")
        let body = try JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])
        let data = try await authorised(url: url, method: "POST", body: body)
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw NetworkError.decoding(String(describing: error))
        }
    }

    public func hasActiveEntitlement() async throws -> Bool {
        try await rpc("has_active_entitlement", returning: Bool.self)
    }

    // MARK: Edge Functions

    /// Sends a StoreKit 2 `Transaction.jwsRepresentation` to be verified and stored.
    public func verifySubscription(signedTransaction: String) async throws -> Entitlement {
        let body = try JSONSerialization.data(withJSONObject: ["signedTransaction": signedTransaction], options: [])
        let data = try await function("verify-subscription", method: "POST", body: body)
        return try decodeEntitlement(data)
    }

    public func fetchEntitlement() async throws -> Entitlement {
        let data = try await function("entitlement", method: "GET", body: nil)
        return try decodeEntitlement(data)
    }

    /// Deletes the account and, by cascade, every synced row.
    public func deleteAccount() async throws {
        _ = try await function("delete-account", method: "POST", body: Data("{}".utf8))
    }

    // MARK: Plumbing

    private func function(_ name: String, method: String, body: Data?) async throws -> Data {
        let url = try configuration.endpoint("functions/v1/\(name)")
        return try await authorised(url: url, method: method, body: body)
    }

    private func decodeEntitlement(_ data: Data) throws -> Entitlement {
        do {
            return try JSONDecoder().decode(Entitlement.self, from: data)
        } catch {
            throw NetworkError.decoding(String(describing: error))
        }
    }

    private func authorised(url: URL, method: String, body: Data?, headers: [String: String] = [:]) async throws -> Data {
        let token = try await tokens.validAccessToken()
        do {
            return try await http.sendValidated(makeRequest(url: url, method: method, body: body, headers: headers, token: token))
        } catch let error as NetworkError where error.statusCode == 401 {
            let fresh = try await tokens.refreshedAccessToken(after: token)
            return try await http.sendValidated(makeRequest(url: url, method: method, body: body, headers: headers, token: fresh))
        }
    }

    private func makeRequest(url: URL, method: String, body: Data?, headers: [String: String], token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setBearer(token)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// A value inside a PostgREST logic tree (`or=(…)`), double-quoted because timestamps and ids
    /// contain reserved characters (`.`, `:`, `,`).
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
