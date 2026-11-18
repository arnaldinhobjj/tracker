import Foundation

/// An AI backend that can suggest calendar events. Add other providers by conforming to this.
public protocol AIProvider: Sendable {
    /// Stable identifier, also used for the Keychain key name.
    var id: String { get }
    var displayName: String { get }
    func proposeEvents(for summary: RoutineSummary, parser: ProposalParser) async throws -> ProposalParseResult
}

/// Instructions shared by every provider.
public enum SchedulingPrompt {
    public static let system = """
    You are the scheduling assistant inside DayLedger, a personal app that logs the places a person \
    visits and what they spend. You receive an anonymised summary of their recent routine: the named \
    places they visit with typical days and hours, average weekly spending by category, and the times \
    they are already busy.

    Suggest upcoming calendar events that fit the routine you can see, such as a weekly food shop at \
    the usual supermarket and time, or a gym session at their usual hour. Only suggest events \
    supported by a repeated pattern in the data (at least two visits), and say which pattern in \
    `reason`, in one short sentence. Use the place name in the title where it helps \
    (for example "Food shop at Tesco").

    Rules:
    - Every event must start after `today` and within `planningWindowDays` days.
    - Never overlap a `busy` block.
    - Use the user's time zone, given in `timeZone`; write `start` as ISO 8601 with a UTC offset.
    - `durationMinutes` between 5 and 480, based on the typical visit duration.
    - At most 8 proposals. Return an empty list if no pattern is strong enough; that is a fine answer.
    - Use `confidence` "high" only for patterns seen most weeks.
    """

    public static func userMessage(for summary: RoutineSummary) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = String(decoding: try encoder.encode(summary), as: UTF8.self)
        return "Here is my routine summary. Suggest events for the planning window.\n\n\(json)"
    }

    /// JSON schema for structured output. All objects closed; validation of ranges happens in `ProposalParser`.
    public static let responseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "proposals": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "start": ["type": "string", "format": "date-time"],
                        "durationMinutes": ["type": "integer"],
                        "reason": ["type": "string"],
                        "confidence": ["type": "string", "enum": ["low", "medium", "high"]],
                    ],
                    "required": ["title", "start", "durationMinutes", "reason", "confidence"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["proposals"],
        "additionalProperties": false,
    ]
}
