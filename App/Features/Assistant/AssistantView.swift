import AIKit
import SwiftUI

/// Review screen for AI suggestions. Nothing reaches Google Calendar until the user approves it.
struct AssistantView: View {
    let environment: AppEnvironment
    @State var model: AssistantViewModel

    var body: some View {
        NavigationStack {
            List {
                if environment.proAccess != .available {
                    Section {
                        ProUpsellView(environment: environment, title: "AI suggestions are part of Pro", systemImage: "sparkles",
                                      message: "DayLedger Pro proposes events from your routine. Nothing is added to your calendar until you approve it.")
                    }
                } else if !environment.settings.aiAssistantEnabled || !model.hasAPIKey {
                    Section {
                        ContentUnavailableView {
                            Label("AI assistant is off", systemImage: "sparkles")
                        } description: {
                            Text("Connect an AI provider with your own API key in Settings → AI assistant. It's optional: everything else works without it.")
                        }
                    }
                } else {
                    Section {
                        Button {
                            Task { await model.requestSuggestions() }
                        } label: {
                            HStack {
                                Label("Suggest events from my routine", systemImage: "sparkles")
                                Spacer()
                                if model.isLoading { ProgressView() }
                            }
                        }
                        .disabled(model.isLoading)
                        .accessibilityIdentifier("suggestButton")
                    } footer: {
                        Text("Sends an anonymised summary (place names, usual days and times, weekly spend per category rounded to £5, busy/free times) to \(model.provider?.displayName ?? "the provider").")
                    }

                    if let error = model.error {
                        Section {
                            Label(error.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(error.message).font(.footnote)
                        }
                    }
                    if let message = model.resultMessage {
                        Section { Text(message).foregroundStyle(.secondary) }
                    }

                    if !model.proposals.isEmpty {
                        Section {
                            ForEach(model.proposals) { proposal in
                                ProposalRow(proposal: proposal, decision: model.decisions[proposal.id] ?? .pending) { decision in
                                    model.set(decision, for: proposal)
                                }
                            }
                        } header: {
                            HStack {
                                Text("Suggestions")
                                Spacer()
                                Button("Approve all") { model.approveAll() }
                                    .font(.caption.weight(.semibold))
                                    .textCase(nil)
                            }
                        } footer: {
                            if model.rejectedCount > 0 {
                                Text("\(model.rejectedCount) suggestion(s) were discarded because they were invalid or clashed with your calendar.")
                            }
                        }

                        Section {
                            Button {
                                Task { await model.createApproved() }
                            } label: {
                                HStack {
                                    Text(model.approvedProposals.isEmpty
                                         ? "Approve suggestions to add them"
                                         : "Add \(model.approvedProposals.count) approved to calendar")
                                    Spacer()
                                    if model.isCreating { ProgressView() }
                                }
                            }
                            .disabled(model.approvedProposals.isEmpty || model.isCreating || !environment.calendarSync.isSignedIn)
                        } footer: {
                            if !environment.calendarSync.isSignedIn {
                                Text("Sign in with Google in Settings to add events.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Suggestions")
        }
    }
}

private struct ProposalRow: View {
    let proposal: EventProposal
    let decision: AssistantViewModel.Decision
    var onDecide: (AssistantViewModel.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(proposal.title).font(.body.weight(.medium))
                Spacer()
                Text(proposal.confidence.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text("\(proposal.start.formatted(.dateTime.weekday(.abbreviated).day().month().hour().minute())) · \(proposal.durationMinutes) min")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !proposal.reason.isEmpty {
                Text(proposal.reason).font(.caption)
            }
            HStack {
                Button {
                    onDecide(decision == .approved ? .pending : .approved)
                } label: {
                    Label("Approve", systemImage: decision == .approved ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .tint(.green)
                Button {
                    onDecide(decision == .rejected ? .pending : .rejected)
                } label: {
                    Label("Reject", systemImage: decision == .rejected ? "xmark.circle.fill" : "xmark.circle")
                }
                .tint(.red)
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
        .padding(.vertical, 4)
        .opacity(decision == .rejected ? 0.5 : 1)
    }
}
