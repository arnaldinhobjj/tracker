import XCTest
@testable import AIKit

/// The AI's output is untrusted: these tests pin down what gets accepted and what is dropped.
final class ProposalParserTests: XCTestCase {
    let london = TimeZone(identifier: "Europe/London")!
    // Wednesday 6 March 2024, 12:00 London.
    var now: Date { londonDate(2024, 3, 6, 12) }

    func parser(busy: [DateInterval] = []) -> ProposalParser {
        ProposalParser(now: now, timeZone: london, planningWindowDays: 14, maxProposals: 10, busy: busy)
    }

    func testParsesValidProposals() throws {
        let json = """
        {"proposals":[
          {"title":"Food shop at Tesco","start":"2024-03-09T10:00:00+00:00","durationMinutes":45,
           "reason":"You shop at Tesco most Saturdays around 10:00.","confidence":"high"},
          {"title":"Gym","start":"2024-03-07T07:00:00Z","durationMinutes":60,"reason":"Usual weekday gym time.","confidence":"medium"}
        ]}
        """
        let result = try parser().parse(json)
        XCTAssertEqual(result.proposals.map(\.title), ["Gym", "Food shop at Tesco"], "Sorted by start")
        XCTAssertEqual(result.proposals.last?.start, londonDate(2024, 3, 9, 10))
        XCTAssertEqual(result.proposals.last?.durationMinutes, 45)
        XCTAssertEqual(result.proposals.last?.confidence, .high)
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testLocalTimeWithoutOffsetUsesUsersTimeZone() throws {
        // 9 July is during BST: 10:00 local is 09:00 UTC.
        let summer = ProposalParser(now: londonDate(2024, 7, 3, 12), timeZone: london)
        let result = try summer.parse(#"{"proposals":[{"title":"Shop","start":"2024-07-06T10:00:00","durationMinutes":30,"reason":"r","confidence":"low"}]}"#)
        XCTAssertEqual(result.proposals.first?.start, londonDate(2024, 7, 6, 10))
    }

    func testRejectsPastFarFutureAndInvalidItems() throws {
        let json = """
        {"proposals":[
          {"title":"Yesterday","start":"2024-03-05T10:00:00Z","durationMinutes":30,"reason":"","confidence":"low"},
          {"title":"Next month","start":"2024-04-20T10:00:00Z","durationMinutes":30,"reason":"","confidence":"low"},
          {"title":"Zero length","start":"2024-03-08T10:00:00Z","durationMinutes":0,"reason":"","confidence":"low"},
          {"title":"All week","start":"2024-03-08T10:00:00Z","durationMinutes":10000,"reason":"","confidence":"low"},
          {"title":"Bad date","start":"next Tuesday","durationMinutes":30,"reason":"","confidence":"low"},
          {"title":"","start":"2024-03-08T10:00:00Z","durationMinutes":30,"reason":"","confidence":"low"},
          {"start":"2024-03-08T10:00:00Z","durationMinutes":30},
          {"title":"OK","start":"2024-03-08T10:00:00Z","durationMinutes":30,"reason":"fine","confidence":"low"}
        ]}
        """
        let result = try parser().parse(json)
        XCTAssertEqual(result.proposals.map(\.title), ["OK"])
        XCTAssertEqual(result.rejected.count, 7)
        XCTAssertEqual(Set(result.rejected.map(\.reason)),
                       ["in the past", "beyond the planning window", "invalid duration", "invalid start time", "missing title"])
    }

    func testRejectsClashesWithBusyTimeButAllowsBackToBack() throws {
        let busy = [DateInterval(start: londonDate(2024, 3, 8, 9), end: londonDate(2024, 3, 8, 10))]
        let json = """
        {"proposals":[
          {"title":"Clash","start":"2024-03-08T09:30:00Z","durationMinutes":60,"reason":"","confidence":"low"},
          {"title":"Right after","start":"2024-03-08T10:00:00Z","durationMinutes":30,"reason":"","confidence":"low"}
        ]}
        """
        let result = try parser(busy: busy).parse(json)
        XCTAssertEqual(result.proposals.map(\.title), ["Right after"])
        XCTAssertEqual(result.rejected.first?.reason, "clashes with an existing event")
    }

    func testDropsDuplicatesAndCapsCount() throws {
        var items: [String] = []
        for day in 7...19 {
            items.append(#"{"title":"Walk","start":"2024-03-\#(String(format: "%02d", day))T08:00:00Z","durationMinutes":30,"reason":"","confidence":"low"}"#)
        }
        items.append(#"{"title":"walk","start":"2024-03-07T08:00:00Z","durationMinutes":30,"reason":"","confidence":"low"}"#)
        let result = try parser().parse(#"{"proposals":[\#(items.joined(separator: ","))]}"#)
        XCTAssertEqual(result.proposals.count, 10)
        XCTAssertTrue(result.rejected.contains { $0.reason == "duplicate" })
        XCTAssertTrue(result.rejected.contains { $0.reason == "too many proposals" })
    }

    func testUnknownConfidenceDefaultsToMediumAndLongReasonIsTrimmed() throws {
        let longReason = String(repeating: "x", count: 1_000)
        let result = try parser().parse(#"{"proposals":[{"title":"T","start":"2024-03-08T10:00:00Z","durationMinutes":30,"reason":"\#(longReason)","confidence":"certain"}]}"#)
        XCTAssertEqual(result.proposals.first?.confidence, .medium)
        XCTAssertEqual(result.proposals.first?.reason.count, 300)
    }

    func testToleratesCodeFencesAndProse() throws {
        let text = """
        Here are some ideas:
        ```json
        {"proposals":[{"title":"Gym","start":"2024-03-07T07:00:00Z","durationMinutes":60,"reason":"r","confidence":"high"}]}
        ```
        """
        XCTAssertEqual(try parser().parse(text).proposals.count, 1)
    }

    func testEmptyListIsValid() throws {
        XCTAssertTrue(try parser().parse(#"{"proposals":[]}"#).proposals.isEmpty)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try parser().parse("not json")) {
            guard case AIError.invalidResponse = $0 else { return XCTFail("wrong error \($0)") }
        }
        XCTAssertThrowsError(try parser().parse(#"{"events":[]}"#))
        XCTAssertThrowsError(try parser().parse(#"{"proposals":[{"title":"Unclosed"#))
    }
}
