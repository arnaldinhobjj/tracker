import Foundation

/// A calendar event suggested by the AI. Nothing is written until the user approves it.
public struct EventProposal: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var durationMinutes: Int
    public var reason: String
    public var confidence: Confidence

    public enum Confidence: String, Codable, Sendable, CaseIterable {
        case low, medium, high
    }

    public init(id: String, title: String, start: Date, durationMinutes: Int, reason: String, confidence: Confidence) {
        self.id = id
        self.title = title
        self.start = start
        self.durationMinutes = durationMinutes
        self.reason = reason
        self.confidence = confidence
    }

    public var end: Date { start.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
}

public struct RejectedProposal: Equatable, Sendable {
    public let title: String
    public let reason: String
}

public struct ProposalParseResult: Equatable, Sendable {
    public var proposals: [EventProposal]
    /// Items the model returned that failed validation (shown in debug builds, never written).
    public var rejected: [RejectedProposal]
}

public enum AIError: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case overloaded
    /// The model declined the request (stop_reason "refusal").
    case refused
    /// The response hit max_tokens before the JSON was complete.
    case truncated
    case invalidResponse(String)
    case providerError(status: Int, message: String)
    case offline
    case network(String)
}

/// Parses and validates the model's JSON. The model's output is treated as untrusted input:
/// every field is checked, and anything invalid is dropped rather than written to a calendar.
public struct ProposalParser: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var planningWindowDays: Int
    public var maxProposals: Int
    public var busy: [DateInterval]

    public static let allowedDurations = 5...480

    public init(now: Date, timeZone: TimeZone = .current, planningWindowDays: Int = 14, maxProposals: Int = 10, busy: [DateInterval] = []) {
        self.now = now
        self.timeZone = timeZone
        self.planningWindowDays = planningWindowDays
        self.maxProposals = maxProposals
        self.busy = busy
    }

    struct Payload: Decodable {
        struct Item: Decodable {
            let title: String?
            let start: String?
            let durationMinutes: Int?
            let reason: String?
            let confidence: String?
        }
        let proposals: [Item]?
    }

    public func parse(_ text: String) throws -> ProposalParseResult {
        guard let data = Self.extractJSON(from: text).data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw AIError.invalidResponse("The AI response wasn't valid JSON.")
        }
        guard let items = payload.proposals else {
            throw AIError.invalidResponse("The AI response had no proposals list.")
        }

        var accepted: [EventProposal] = []
        var rejected: [RejectedProposal] = []
        var seen = Set<String>()
        let horizon = now.addingTimeInterval(TimeInterval(planningWindowDays) * 86_400)

        for item in items {
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            func reject(_ why: String) { rejected.append(RejectedProposal(title: title.isEmpty ? "(untitled)" : title, reason: why)) }

            guard !title.isEmpty else { reject("missing title"); continue }
            guard title.count <= 100 else { reject("title too long"); continue }
            guard let startText = item.start, let start = parseDate(startText) else { reject("invalid start time"); continue }
            guard start > now else { reject("in the past"); continue }
            guard start <= horizon else { reject("beyond the planning window"); continue }
            guard let duration = item.durationMinutes, Self.allowedDurations.contains(duration) else { reject("invalid duration"); continue }
            let interval = DateInterval(start: start, duration: TimeInterval(duration * 60))
            guard !busy.contains(where: { $0.intersects(interval) && $0.intersection(with: interval)?.duration ?? 0 > 0 }) else {
                reject("clashes with an existing event"); continue
            }
            let key = "\(title.lowercased())|\(Int(start.timeIntervalSince1970))"
            guard seen.insert(key).inserted else { reject("duplicate"); continue }
            guard accepted.count < maxProposals else { reject("too many proposals"); continue }

            let reason = String((item.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            accepted.append(EventProposal(
                id: key,
                title: title,
                start: start,
                durationMinutes: duration,
                reason: reason,
                confidence: EventProposal.Confidence(rawValue: (item.confidence ?? "").lowercased()) ?? .medium
            ))
        }
        return ProposalParseResult(proposals: accepted.sorted { $0.start < $1.start }, rejected: rejected)
    }

    /// Accepts "2024-03-09T10:00:00Z", "...+00:00", and local times without an offset
    /// ("2024-03-09T10:00:00", interpreted in the user's time zone).
    func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Strips Markdown code fences or leading prose if a provider doesn't support strict JSON output.
    static func extractJSON(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return trimmed }
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end {
            return String(trimmed[start...end])
        }
        return trimmed
    }
}
