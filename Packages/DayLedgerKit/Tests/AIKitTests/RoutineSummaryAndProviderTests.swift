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

final class AnthropicProviderTests: XCTestCase {
    let parser = ProposalParser(now: londonDate(2024, 3, 6, 12), timeZone: TimeZone(identifier: "Europe/London")!)
    let summary = RoutineSummary(today: "2024-03-06T12:00:00Z", timeZone: "Europe/London", periodDays: 28,
                                 places: [], spending: [], busy: [], planningWindowDays: 14)

    func testBuildsRequestWithKeyHeadersAndStructuredOutput() throws {
        let provider = AnthropicProvider(http: StubHTTPClient(), apiKey: { "sk-ant-test" })
        let request = try provider.makeRequest(summary: summary)
        XCTAssertEqual(request.url, AnthropicProvider.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        let outputConfig = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual((outputConfig["format"] as? [String: Any])?["type"] as? String, "json_schema")
        XCTAssertNil(body["tool_choice"], "Forced tool use is not supported on this model")
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        let http = StubHTTPClient()
        let provider = AnthropicProvider(http: http, apiKey: { nil })
        do {
            _ = try await provider.proposeEvents(for: summary, parser: parser)
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? AIError, .missingAPIKey)
            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    func testParsesTextBlockAndSkipsThinking() async throws {
        let http = StubHTTPClient()
        let proposals = #"{\"proposals\":[{\"title\":\"Gym\",\"start\":\"2024-03-07T07:00:00Z\",\"durationMinutes\":60,\"reason\":\"r\",\"confidence\":\"high\"}]}"#
        http.on("/v1/messages", body: #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"\#(proposals)"}],"stop_reason":"end_turn"}"#)
        let result = try await AnthropicProvider(http: http, apiKey: { "k" }).proposeEvents(for: summary, parser: parser)
        XCTAssertEqual(result.proposals.map(\.title), ["Gym"])
    }

    func testRefusalAndTruncationAndBadKey() async {
        func run(status: Int = 200, body: String) async -> AIError? {
            let http = StubHTTPClient()
            http.on("/v1/messages", status: status, body: body)
            do {
                _ = try await AnthropicProvider(http: http, apiKey: { "k" }).proposeEvents(for: summary, parser: parser)
                return nil
            } catch {
                return error as? AIError
            }
        }
        let refused = await run(body: #"{"content":[],"stop_reason":"refusal"}"#)
        XCTAssertEqual(refused, .refused)
        let truncated = await run(body: #"{"content":[{"type":"text","text":"{\"proposals\":["}],"stop_reason":"max_tokens"}"#)
        XCTAssertEqual(truncated, .truncated)
        let badKey = await run(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        XCTAssertEqual(badKey, .invalidAPIKey)
        let busy = await run(status: 529, body: #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)
        XCTAssertEqual(busy, .overloaded)
    }
}
