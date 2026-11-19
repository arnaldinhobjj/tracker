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

    /// Hard-deletes the user's rows by id: `DELETE /rest/v1/<table>?user_id=eq.<uid>&id=in.(…)`.
    /// Used instead of a soft delete when the user has no active entitlement (RLS then allows
    /// deleting own rows but not updating them). Ids go in quoted batches of 100.
    public func delete(from table: String, userID: UUID, ids: [String]) async throws {
        var start = 0
        while start < ids.count {
            let end = min(start + 100, ids.count)
            let list = ids[start..<end].map(Self.quoted).joined(separator: ",")
            let url = try configuration.endpoint("rest/v1/\(table)", query: [
                URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
                URLQueryItem(name: "id", value: "in.(\(list))"),
            ])
            _ = try await authorised(url: url, method: "DELETE", body: nil, headers: ["Prefer": "return=minimal"])
            start = end
        }
    }

    /// Hard-deletes every row the user has in `table`: `DELETE /rest/v1/<table>?user_id=eq.<uid>`.
    /// Allowed without a subscription (removing visit sync, starting encryption over).
    public func deleteAll(from table: String, userID: UUID) async throws {
        let url = try configuration.endpoint("rest/v1/\(table)", query: [
            URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
        ])
        _ = try await authorised(url: url, method: "DELETE", body: nil, headers: ["Prefer": "return=minimal"])
    }

    // MARK: Encryption key registry (`public.sync_keys`)

    /// The id of the key the account's rows are encrypted with, or nil when none is registered.
    public func fetchSyncKey() async throws -> SyncKeyRecord? {
        let url = try configuration.endpoint("rest/v1/sync_keys", query: [
            URLQueryItem(name: "select", value: "user_id,key_id"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        let data = try await authorised(url: url, method: "GET", body: nil)
        do {
            return try JSONDecoder().decode([SyncKeyRecord].self, from: data).first
        } catch {
            throw NetworkError.decoding(String(describing: error))
        }
    }

    /// Registers a key id unless the account already has one (`ON CONFLICT DO NOTHING`), so two
    /// devices racing to create the first key can't overwrite each other. Read back to see who won.
    public func registerSyncKey(_ record: SyncKeyRecord) async throws {
        let url = try configuration.endpoint("rest/v1/sync_keys", query: [URLQueryItem(name: "on_conflict", value: "user_id")])
        let body = try JSONEncoder().encode([record])
        _ = try await authorised(url: url, method: "POST", body: body, headers: [
            "Prefer": "resolution=ignore-duplicates,return=minimal",
        ])
    }

    public func deleteSyncKey(userID: UUID) async throws {
        try await deleteAll(from: "sync_keys", userID: userID)
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
        var last = cursor
        try await forEachChangePage(type, from: table, after: cursor, hasIDColumn: hasIDColumn, pageSize: pageSize) { page, position in
            all.append(contentsOf: page)
            last = position
        }
        return (all, last)
    }

    /// Every row changed after `cursor`, one page at a time: `body` gets each page and the cursor
    /// to store once that page has been applied. Pages are fetched only after `body` returns, so
    /// a caller that saves the cursor in `body` can resume an interrupted pull where it stopped.
    public func forEachChangePage<Row: SyncRow>(_ type: Row.Type, from table: String, after cursor: SyncCursor?,
                                                hasIDColumn: Bool = true, pageSize: Int = SupabaseRESTClient.pageSize,
                                                _ body: ([Row], SyncCursor?) async throws -> Void) async throws {
        var position = cursor
        var more = true
        while more {
            let page = try await fetchPage(type, from: table, after: position, hasIDColumn: hasIDColumn, limit: pageSize)
            (position, more) = Self.advance(position, after: page, hasIDColumn: hasIDColumn, pageSize: pageSize)
            try await body(page, position)
        }
    }

    /// The cursor after `page`, and whether another page may follow (a short page is the last; so is
    /// a full page without a usable cursor, which would otherwise loop forever).
    public static func advance<Row: SyncRow>(_ cursor: SyncCursor?, after page: [Row], hasIDColumn: Bool = true,
                                             pageSize: Int = SupabaseRESTClient.pageSize) -> (cursor: SyncCursor?, hasMore: Bool) {
        guard let last = page.last, let updatedAt = last.updatedAt else {
            return (cursor, false)
        }
        let next = SyncCursor(updatedAt: updatedAt, id: hasIDColumn ? last.cursorID : nil)
        return (next, page.count >= pageSize)
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

    /// `POST /functions/v1/<name>` with a JSON body, as the signed-in user. Returns the response body.
    /// `timeout` overrides URLSession's 60-second default for functions that wait on a slow upstream.
    /// `attester` adds App Attest headers for functions that check them.
    public func invokeFunction(_ name: String, body: Data, timeout: TimeInterval? = nil,
                               attester: RequestAttesting? = nil) async throws -> Data {
        try await function(name, method: "POST", body: body, timeout: timeout, attester: attester)
    }

    /// Deletes the account and, by cascade, every synced row.
    public func deleteAccount() async throws {
        _ = try await function("delete-account", method: "POST", body: Data("{}".utf8))
    }

    // MARK: Plumbing

    private func function(_ name: String, method: String, body: Data?, timeout: TimeInterval? = nil,
                          attester: RequestAttesting? = nil) async throws -> Data {
        let url = try configuration.endpoint("functions/v1/\(name)")
        let client = attester.map { AttestingHTTPClient(base: http, attester: $0) } ?? http
        return try await authorised(url: url, method: method, body: body, timeout: timeout, http: client)
    }

    private func decodeEntitlement(_ data: Data) throws -> Entitlement {
        do {
            return try JSONDecoder().decode(Entitlement.self, from: data)
        } catch {
            throw NetworkError.decoding(String(describing: error))
        }
    }

    private func authorised(url: URL, method: String, body: Data?, headers: [String: String] = [:],
                            timeout: TimeInterval? = nil, http: HTTPClient? = nil) async throws -> Data {
        let http = http ?? self.http
        let token = try await tokens.validAccessToken()
        do {
            return try await http.sendValidated(makeRequest(url: url, method: method, body: body, headers: headers, token: token, timeout: timeout))
        } catch let error as NetworkError where error.statusCode == 401 {
            let fresh = try await tokens.refreshedAccessToken(after: token)
            return try await http.sendValidated(makeRequest(url: url, method: method, body: body, headers: headers, token: fresh, timeout: timeout))
        }
    }

    private func makeRequest(url: URL, method: String, body: Data?, headers: [String: String], token: String,
                             timeout: TimeInterval? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
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
