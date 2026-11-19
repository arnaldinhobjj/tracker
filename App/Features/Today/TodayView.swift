import SharedModels
import SwiftUI
import UIKit

struct TodayView: View {
    @State var model: TodayViewModel
    var connectBank: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summary
                }

                if let error = model.error {
                    Section {
                        ErrorBanner(error: error) {
                            switch error.action {
                            case .reconnectBank: connectBank()
                            case .retry: Task { await model.refresh() }
                            case .none, .openSettings, .signInGoogle: break
                            }
                        }
                    }
                }

                if !model.hasConnection {
                    Section {
                        ContentUnavailableView {
                            Label("No bank connected", systemImage: "building.columns")
                        } description: {
                            Text("Connect a UK bank account to see today's spending.")
                        } actions: {
                            Button("Connect a bank", action: connectBank)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Section("Transactions") {
                        if model.transactions.isEmpty {
                            Text("No transactions yet today.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.transactions) { transaction in
                                TransactionRow(transaction: transaction)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Today")
            .refreshable { await model.refresh() }
            .task { await model.onAppear() }
            .overlay(alignment: .top) {
                if model.isRefreshing && model.transactions.isEmpty {
                    ProgressView().padding()
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spent today")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                // Read once, as the total's label.
                .accessibilityHidden(true)
            Text(MoneyFormatting.string(minorUnits: model.totalSpentMinor))
                // Scales with Dynamic Type; shrinks rather than wrapping a long amount.
                .font(.system(.largeTitle, design: .rounded, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .accessibilityLabel("Spent today")
                .accessibilityValue(MoneyFormatting.string(minorUnits: model.totalSpentMinor))
                .accessibilityIdentifier("todayTotal")
            if let lastUpdated = model.lastUpdated {
                Text("Updated \(lastUpdated.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

struct ErrorBanner: View {
    let error: UserFacingError
    var onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(error.message)
                .font(.subheadline)
            switch error.action {
            case .reconnectBank:
                Button("Reconnect", action: onAction).buttonStyle(.bordered)
            case .retry:
                Button("Try again", action: onAction).buttonStyle(.bordered)
            case .openSettings:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
            case .none, .signInGoogle:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("errorBanner")
    }
}
