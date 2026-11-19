import Foundation

/// An AI backend that can suggest calendar events.
public protocol AIProvider: Sendable {
    /// Stable identifier.
    var id: String { get }
    var displayName: String { get }
    func proposeEvents(for summary: RoutineSummary, parser: ProposalParser) async throws -> ProposalParseResult
}
