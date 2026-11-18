import Foundation
import Networking

/// Minimal Google Calendar API v3 client: the DayLedger calendar, idempotent event writes
/// and free/busy lookups.
public struct GoogleCalendarClient: Sendable {
    public static let calendarName = "DayLedger"
    static let baseURL = URL(string: "https://www.googleapis.com/calendar/v3")!

    private let tokens: GoogleAccessTokenProviding
    private let http: HTTPClient

    public init(tokens: GoogleAccessTokenProviding, http: HTTPClient = URLSessionHTTPClient()) {
        self.tokens = tokens
        self.http = http
    }

    // MARK: Calendar

    /// Returns the DayLedger calendar's ID, creating the calendar if needed.
    /// `knownID` is the ID remembered from last time; it is verified first.
    public func ensureDayLedgerCalendar(knownID: String?, timeZone: TimeZone = .current) async throws -> String {
        if let knownID {
            do {
                _ = try await send("GET", "/calendars/\(escape(knownID))")
                return knownID
            } catch CalendarError.calendarNotFound {
                // Deleted by the user: fall through and look it up or recreate it.
            }
        }

        let list: CalendarList = try await decode(send("GET", "/users/me/calendarList", query: [URLQueryItem(name: "minAccessRole", value: "owner")]))
        if let existing = list.items?.first(where: { $0.summary == Self.calendarName }) {
            return existing.id
        }

        let body = NewCalendar(summary: Self.calendarName,
                               description: "Places you visited and what you spent, logged automatically by the DayLedger app.",
                               timeZone: timeZone.identifier)
        let created: CalendarResource = try await decode(send("POST", "/calendars", body: body))
        return created.id
    }

    public func deleteCalendar(id: String) async throws {
        do {
            _ = try await send("DELETE", "/calendars/\(escape(id))")
        } catch CalendarError.calendarNotFound {
            // Already gone.
        }
    }

    // MARK: Events

    public enum UpsertResult: Equatable, Sendable { case created, updated }

    /// Creates the event with its deterministic ID, or updates it if it already exists.
    /// Running this twice for the same draft never creates a duplicate.
    @discardableResult
    public func upsert(_ draft: CalendarEventDraft, calendarID: String) async throws -> UpsertResult {
        let body = EventBody(draft)
        do {
            _ = try await send("POST", "/calendars/\(escape(calendarID))/events", body: body)
            return .created
        } catch CalendarError.api(status: 409, message: _) {
            _ = try await send("PUT", "/calendars/\(escape(calendarID))/events/\(escape(draft.id))", body: body)
            return .updated
        }
    }

    // MARK: Free/busy

    /// Busy intervals on the user's primary calendar. Only times, never titles or details.
    public func busyIntervals(from start: Date, to end: Date, calendarIDs: [String] = ["primary"]) async throws -> [DateInterval] {
        let body = FreeBusyRequest(timeMin: Self.rfc3339(start), timeMax: Self.rfc3339(end), items: calendarIDs.map { .init(id: $0) })
        let response: FreeBusyResponse = try await decode(send("POST", "/freeBusy", body: body))
        return (response.calendars ?? [:]).values
            .flatMap { $0.busy ?? [] }
            .compactMap { period in
                guard let s = Self.parseRFC3339(period.start), let e = Self.parseRFC3339(period.end), e > s else { return nil }
                return DateInterval(start: s, end: e)
            }
            .sorted { $0.start < $1.start }
    }

    // MARK: Transport

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Encodable? = nil) async throws -> Data {
        var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = Self.baseURL.path + path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        request.setBearer(try await tokens.accessToken())
        do {
            return try await http.sendValidated(request)
        } catch NetworkError.unauthorized {
            request.setBearer(try await tokens.refreshAccessToken())
            do {
                return try await http.sendValidated(request)
            } catch let error as NetworkError {
                throw Self.map(error)
            }
        } catch let error as NetworkError {
            throw Self.map(error)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CalendarError.network(.decoding(String(describing: error)))
        }
    }

    private func escape(_ component: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    static func map(_ error: NetworkError) -> CalendarError {
        let message = APIErrorBody.message(error.body) ?? ""
        switch error {
        case .unauthorized:
            return .reauthenticationRequired
        case .forbidden(let body):
            let text = (body ?? "").lowercased()
            if text.contains("ratelimitexceeded") || text.contains("userratelimitexceeded") { return .rateLimited }
            return .insufficientPermissions
        case .http(404, _), .http(410, _):
            return .calendarNotFound
        case .http(429, _):
            return .rateLimited
        case .http(let status, _):
            return .api(status: status, message: message)
        default:
            return .network(error)
        }
    }

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func parseRFC3339(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Wire formats

private struct CalendarList: Decodable {
    struct Entry: Decodable {
        let id: String
        let summary: String?
    }
    let items: [Entry]?
}

private struct CalendarResource: Decodable {
    let id: String
}

private struct NewCalendar: Encodable {
    let summary: String
    let description: String
    let timeZone: String
}

struct EventBody: Encodable {
    struct When: Encodable {
        let dateTime: String
        let timeZone: String
    }
    struct Properties: Encodable {
        let `private`: [String: String]
    }
    struct Reminders: Encodable {
        let useDefault: Bool
    }

    let id: String
    let summary: String
    let description: String
    let start: When
    let end: When
    let location: String?
    let transparency: String
    let extendedProperties: Properties
    let reminders: Reminders

    init(_ draft: CalendarEventDraft) {
        id = draft.id
        summary = draft.summary
        description = draft.description
        start = When(dateTime: GoogleCalendarClient.rfc3339(draft.start), timeZone: draft.timeZone.identifier)
        end = When(dateTime: GoogleCalendarClient.rfc3339(draft.end), timeZone: draft.timeZone.identifier)
        location = draft.location
        transparency = draft.showsAsBusy ? "opaque" : "transparent"
        extendedProperties = Properties(private: draft.privateProperties)
        // Logged visits are in the past; no notifications.
        reminders = Reminders(useDefault: draft.showsAsBusy)
    }
}

private struct FreeBusyRequest: Encodable {
    struct Item: Encodable { let id: String }
    let timeMin: String
    let timeMax: String
    let items: [Item]
}

private struct FreeBusyResponse: Decodable {
    struct CalendarBusy: Decodable {
        struct Period: Decodable {
            let start: String
            let end: String
        }
        let busy: [Period]?
    }
    let calendars: [String: CalendarBusy]?
}

private struct APIErrorBody: Decodable {
    struct Inner: Decodable { let message: String? }
    let error: Inner?

    static func message(_ body: String?) -> String? {
        guard let data = body?.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.error?.message
    }
}
