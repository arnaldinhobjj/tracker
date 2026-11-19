import XCTest
@testable import AIKit
import Networking
import SharedModels

final class RoutineSummaryTests: XCTestCase {
    func makeSummary() -> RoutineSummary {
        let now = londonDate(2024, 3, 20, 12)
        var visits: [PlaceVisit] = []
        // Tesco three Saturdays at 10:00, a gym twice on Tuesdays, and an address-only visit (home).
        for day in [2, 9, 16] {
            visits.append(PlaceVisit(id: "t\(day)", arrival: londonDate(2024, 3, day, 10), departure: londonDate(2024, 3, day, 10, 40),
                                     latitude: 51.512345, longitude: -0.123456, placeName: "Tesco Extra", placeCategory: "MKPOICategoryStore", isNamedPlace: true))
        }
        for day in [5, 12] {
            visits.append(PlaceVisit(id: "g\(day)", arrival: londonDate(2024, 3, day, 7), departure: londonDate(2024, 3, day, 8),
                                     latitude: 51.5, longitude: -0.1, placeName: "PureGym", placeCategory: "MKPOICategoryFitnessCenter", isNamedPlace: true))
        }
        visits.append(PlaceVisit(id: "home", arrival: londonDate(2024, 3, 18, 19), departure: londonDate(2024, 3, 19, 8),
                                 latitude: 51.4, longitude: -0.2, placeName: "12 Acacia Avenue", isNamedPlace: false))

        let transactions = [
            BankTransaction(id: "acct-123:tx-1", accountID: "acct-123", merchant: "Tesco Extra", rawDescription: "TESCO STORES 3412 CARD 4421",
                            amountMinor: 6_150, direction: .debit, bankCategory: "PURCHASE", category: .groceries,
                            timestamp: londonDate(2024, 3, 16, 10, 30), hasTime: true, isPending: false),
            BankTransaction(id: "acct-123:tx-2", accountID: "acct-123", merchant: "Tesco Extra", rawDescription: "TESCO STORES",
                            amountMinor: 5_850, direction: .debit, bankCategory: "PURCHASE", category: .groceries,
                            timestamp: londonDate(2024, 3, 9, 10, 30), hasTime: true, isPending: false),
            BankTransaction(id: "acct-123:tx-3", accountID: "acct-123", merchant: "Savings", rawDescription: "TO SAVINGS 12345678",
                            amountMinor: 50_000, direction: .debit, bankCategory: "TRANSFER", category: .transfer,
                            timestamp: londonDate(2024, 3, 10), hasTime: false, isPending: false),
        ]
        let busy = [DateInterval(start: londonDate(2024, 3, 21, 9, 7), end: londonDate(2024, 3, 21, 9, 52))]
        return RoutineSummaryBuilder(calendar: .london).build(visits: visits, transactions: transactions, busy: busy, now: now)
    }

    func testSummarisesPatterns() {
        let summary = makeSummary()
        XCTAssertEqual(summary.places.map(\.name), ["Tesco Extra", "PureGym"])
        XCTAssertEqual(summary.places.first?.visitsInPeriod, 3)
        XCTAssertEqual(summary.places.first?.typicalSlots.first, .init(weekday: "Saturday", hour: 10, count: 3))
        XCTAssertEqual(summary.places.first?.typicalDurationMinutes, 40)
        XCTAssertEqual(summary.places.first?.category, "Store")
        // £120 over 4 weeks = £30/week; the transfer is not spending.
        XCTAssertEqual(summary.spending, [.init(category: "Groceries", weeklyAverageRoundedGBP: 30)])
        // Busy block rounded outwards to quarter hours.
        XCTAssertEqual(summary.busy.count, 1)
        XCTAssertTrue(summary.busy[0].start.hasPrefix("2024-03-21T09:00:00"))
        XCTAssertTrue(summary.busy[0].end.hasPrefix("2024-03-21T10:00:00"))
    }

    func testSummaryContainsNoSensitiveDetails() throws {
        let json = String(decoding: try JSONEncoder().encode(makeSummary()), as: UTF8.self)
        for forbidden in ["51.5", "-0.12", "Acacia", "acct-123", "tx-1", "TESCO STORES", "4421", "12345678", "Savings", "6150", "61.5"] {
            XCTAssertFalse(json.contains(forbidden), "Summary leaked \(forbidden): \(json)")
        }
    }
}

/// The request and error handling of the Anthropic call itself are tested with the Edge Function
/// (supabase/functions/_shared/ai_test.ts). Here: what the app sends and how it reads the answer.
final class BackendAIProviderTests: XCTestCase {
    let parser = ProposalParser(now: londonDate(2024, 3, 6, 12), timeZone: TimeZone(identifier: "Europe/London")!)
    let summary = RoutineSummary(today: "2024-03-06T12:00:00Z", timeZone: "Europe/London", periodDays: 28,
                                 places: [], spending: [], busy: [], planningWindowDays: 14)

    private final class Recorder: @unchecked Sendable {
        var bodies: [Data] = []
    }

    func testSendsOnlyTheSummaryAndParsesTheProposals() async throws {
        let recorder = Recorder()
        let text = #"{"proposals":[{"title":"Gym","start":"2024-03-07T07:00:00Z","durationMinutes":60,"reason":"r","confidence":"high"}]}"#
        let reply = try JSONSerialization.data(withJSONObject: ["text": text])
        let provider = BackendAIProvider { body in
            recorder.bodies.append(body)
            return reply
        }

        let result = try await provider.proposeEvents(for: summary, parser: parser)

        XCTAssertEqual(result.proposals.map(\.title), ["Gym"])
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.bodies.first)) as? [String: Any])
        XCTAssertEqual(Array(sent.keys), ["summary"], "Nothing but the anonymised summary")
        XCTAssertEqual((sent["summary"] as? [String: Any])?["timeZone"] as? String, "Europe/London")
    }

    func testBackendErrorsMapToAIErrors() async {
        let cases: [(Int, String, AIError)] = [
            (403, #"{"error":"not_entitled","message":"Pro"}"#, .notEntitled),
            (429, #"{"error":"daily_limit","message":"Limit of 20 reached."}"#, .dailyLimitReached("Limit of 20 reached.")),
            (422, #"{"error":"refused","message":"x"}"#, .refused),
            (502, #"{"error":"truncated","message":"x"}"#, .truncated),
            (503, #"{"error":"provider_busy","message":"x"}"#, .overloaded),
            (400, #"{"error":"invalid_summary","message":"Bad summary."}"#, .providerError(status: 400, message: "Bad summary.")),
        ]
        for (status, body, expected) in cases {
            let provider = BackendAIProvider { _ in throw NetworkError.http(status: status, body: body) }
            do {
                _ = try await provider.proposeEvents(for: summary, parser: parser)
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AIError, expected, "\(status) \(body)")
            }
        }
        let offline = BackendAIProvider { _ in throw NetworkError.offline }
        do {
            _ = try await offline.proposeEvents(for: summary, parser: parser)
            XCTFail("Expected offline")
        } catch {
            XCTAssertEqual(error as? AIError, .offline)
        }
    }

    func testAnUnexpectedBodyIsAnInvalidResponse() async {
        let provider = BackendAIProvider { _ in Data("not json".utf8) }
        do {
            _ = try await provider.proposeEvents(for: summary, parser: parser)
            XCTFail("Expected an error")
        } catch {
            guard case .invalidResponse = error as? AIError else { return XCTFail("\(error)") }
        }
    }
}
