import XCTest
@testable import CalendarKit
import Networking
import SecureStore

private struct FixedTokens: GoogleAccessTokenProviding {
    func accessToken() async throws -> String { "token" }
    func refreshAccessToken() async throws -> String { "token2" }
}

final class GoogleCalendarClientTests: XCTestCase {
    private func draft() -> CalendarEventDraft {
        CalendarEventDraft(id: CalendarEventID.forVisit("abc12345"), summary: "At Costa Coffee", description: "d",
                           start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_800),
                           timeZone: TimeZone(identifier: "Europe/London")!)
    }

    func testUpsertCreatesThenUpdatesOnConflict() async throws {
        let http = StubHTTPClient()
        http.on("/calendars/cal1/events", body: #"{"id":"x"}"#)
        let client = GoogleCalendarClient(tokens: FixedTokens(), http: http)
        let first = try await client.upsert(draft(), calendarID: "cal1")
        XCTAssertEqual(first, .created)

        // Second sync of the same visit: Google says the ID exists, so we PUT instead.
        http.on("/calendars/cal1/events", status: 409, body: #"{"error":{"code":409,"message":"The requested identifier already exists."}}"#)
        http.on("/calendars/cal1/events/\(draft().id)", body: #"{"id":"x"}"#)
        let second = try await client.upsert(draft(), calendarID: "cal1")
        XCTAssertEqual(second, .updated)
        XCTAssertEqual(http.requests.last?.httpMethod, "PUT")

        let body = try XCTUnwrap(http.requests.first?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["id"] as? String, draft().id)
        XCTAssertEqual(json["transparency"] as? String, "transparent")
    }

    func testFindsExistingCalendarInsteadOfCreatingDuplicate() async throws {
        let http = StubHTTPClient()
        http.on("/users/me/calendarList", body: #"{"items":[{"id":"primary@x","summary":"Me"},{"id":"dl@group","summary":"DayLedger"}]}"#)
        let client = GoogleCalendarClient(tokens: FixedTokens(), http: http)
        let id = try await client.ensureDayLedgerCalendar(knownID: nil)
        XCTAssertEqual(id, "dl@group")
        XCTAssertFalse(http.requests.contains { $0.httpMethod == "POST" })
    }

    func testRecreatesCalendarWhenRememberedOneWasDeleted() async throws {
        let http = StubHTTPClient()
        http.on("/calendars/gone", status: 404, body: #"{"error":{"code":404,"message":"Not Found"}}"#)
        http.on("/users/me/calendarList", body: #"{"items":[]}"#)
        http.on("/calendar/v3/calendars", body: #"{"id":"new@group"}"#)
        let client = GoogleCalendarClient(tokens: FixedTokens(), http: http)
        let id = try await client.ensureDayLedgerCalendar(knownID: "gone")
        XCTAssertEqual(id, "new@group")
    }

    func testRetriesOnceWithRefreshedTokenAfter401() async throws {
        let http = StubHTTPClient()
        http.on("/freeBusy", status: 401, body: "{}")
        http.on("/freeBusy", body: #"{"calendars":{"primary":{"busy":[{"start":"2024-03-06T09:00:00Z","end":"2024-03-06T10:00:00Z"}]}}}"#)
        let client = GoogleCalendarClient(tokens: FixedTokens(), http: http)
        let busy = try await client.busyIntervals(from: Date(timeIntervalSince1970: 0), to: Date())
        XCTAssertEqual(busy.count, 1)
        XCTAssertEqual(busy.first?.duration, 3_600)
        XCTAssertEqual(http.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer token2")
    }

    func testForbiddenMapsToInsufficientPermissions() async {
        let http = StubHTTPClient()
        http.on("/freeBusy", status: 403, body: #"{"error":{"code":403,"message":"Request had insufficient authentication scopes."}}"#)
        let client = GoogleCalendarClient(tokens: FixedTokens(), http: http)
        do {
            _ = try await client.busyIntervals(from: Date(), to: Date())
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? CalendarError, .insufficientPermissions)
        }
    }
}

final class GoogleAuthTests: XCTestCase {
    let configuration = GoogleOAuthConfiguration(clientID: "1234-abc.apps.googleusercontent.com")

    func testRedirectUsesReversedClientID() {
        XCTAssertEqual(configuration.callbackScheme, "com.googleusercontent.apps.1234-abc")
        XCTAssertEqual(configuration.redirectURI, "com.googleusercontent.apps.1234-abc:/oauth2redirect")
    }

    func testPKCEChallengeMatchesRFC7636Example() {
        // Test vector from RFC 7636 Appendix B.
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAuthorizationRequestAndExpiredRefreshToken() async throws {
        let http = StubHTTPClient()
        let store = InMemorySecureStore()
        let auth = GoogleAuthService(configuration: configuration, store: store, http: http)
        let request = try auth.makeAuthorizationRequest()
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertNil(items.first { $0.name == "client_secret" })

        try store.setValue(OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: .distantPast), for: SecureStoreKey.googleTokens)
        http.on("/token", status: 400, body: #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)
        do {
            _ = try await auth.accessToken()
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? CalendarError, .reauthenticationRequired)
        }
    }
}
