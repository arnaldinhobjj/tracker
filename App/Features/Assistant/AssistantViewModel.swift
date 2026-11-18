import AIKit
import Foundation
import Observation
import SecureStore

@MainActor
@Observable
final class AssistantViewModel {
    enum Decision: Equatable { case pending, approved, rejected }

    private(set) var proposals: [EventProposal] = []
    private(set) var rejectedCount = 0
    var decisions: [String: Decision] = [:]
    private(set) var isLoading = false
    private(set) var isCreating = false
    private(set) var lastSummary: RoutineSummary?
    private(set) var resultMessage: String?
    var error: UserFacingError?

    private let environment: AppEnvironment
    private let builder = RoutineSummaryBuilder()

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var provider: AIProvider? { environment.aiProviders.first }

    var hasAPIKey: Bool {
        guard let provider else { return false }
        return ((try? environment.secureStore.string(for: SecureStoreKey.aiAPIKey(provider: provider.id))) ?? nil)?.isEmpty == false
    }

    var approvedProposals: [EventProposal] {
        proposals.filter { decisions[$0.id] == .approved }
    }

    /// The exact anonymised data that would be sent. Shown to the user before they send it.
    func buildSummary(now: Date = Date()) async -> (RoutineSummary, [DateInterval]) {
        let periodStart = now.addingTimeInterval(-TimeInterval(builder.periodDays) * 86_400)
        let planningEnd = now.addingTimeInterval(TimeInterval(builder.planningWindowDays) * 86_400)
        let visits = environment.visitRepository.visits(since: periodStart).map(\.domain)
        let transactions = environment.transactionRepository.transactions(from: periodStart, to: now)
        let busy = await environment.calendarSync.busyIntervals(from: now, to: planningEnd)
        return (builder.build(visits: visits, transactions: transactions, busy: busy, now: now), busy)
    }

    func requestSuggestions(now: Date = Date()) async {
        guard let provider, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        error = nil
        resultMessage = nil

        let (summary, busy) = await buildSummary(now: now)
        lastSummary = summary
        do {
            let parser = ProposalParser(now: now, planningWindowDays: builder.planningWindowDays, busy: busy)
            let result = try await provider.proposeEvents(for: summary, parser: parser)
            proposals = result.proposals
            rejectedCount = result.rejected.count
            decisions = Dictionary(uniqueKeysWithValues: result.proposals.map { ($0.id, Decision.pending) })
            if proposals.isEmpty {
                resultMessage = "No suggestions this time. DayLedger needs a few weeks of visits to spot a routine."
            }
        } catch {
            self.error = UserFacingError(error)
        }
    }

    func set(_ decision: Decision, for proposal: EventProposal) {
        decisions[proposal.id] = decision
    }

    func approveAll() {
        for proposal in proposals where decisions[proposal.id] != .rejected {
            decisions[proposal.id] = .approved
        }
    }

    /// Writes only the approved proposals to Google Calendar.
    func createApproved() async {
        let approved = approvedProposals
        guard !approved.isEmpty, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let count = try await environment.calendarSync.createEvents(for: approved)
            let createdIDs = Set(approved.map(\.id))
            proposals.removeAll { createdIDs.contains($0.id) }
            resultMessage = "Added \(count) event\(count == 1 ? "" : "s") to your DayLedger calendar."
            error = nil
        } catch {
            self.error = UserFacingError(error)
        }
    }
}
