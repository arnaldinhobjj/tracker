import AuthenticationServices
import BankKit
import SwiftUI

/// Settings section listing linked banks, with connect / reconnect / disconnect.
struct BankConnectionsSection: View {
    @Bindable var model: BankConnectionViewModel
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        Section {
            if !model.isConfigured {
                Label("Add your TrueLayer client ID to Config/Local.xcconfig to connect a bank.", systemImage: "wrench.and.screwdriver")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.connections) { connection in
                HStack {
                    VStack(alignment: .leading) {
                        Text(connection.providerName)
                        Text(connection.needsReconnect ? "Access expired, reconnect" : "Connected \(connection.connectedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(connection.needsReconnect ? .orange : .secondary)
                    }
                    Spacer()
                    if connection.needsReconnect {
                        Button("Reconnect") { connect() }
                            .buttonStyle(.bordered)
                    }
                }
                .swipeActions {
                    Button("Disconnect", role: .destructive) {
                        Task { await model.disconnect(connection) }
                    }
                }
            }
            Button {
                connect()
            } label: {
                if model.isConnecting {
                    ProgressView()
                } else {
                    Label(model.connections.isEmpty ? "Connect a bank" : "Connect another bank", systemImage: "plus.circle")
                }
            }
            .disabled(!model.isConfigured || model.isConnecting)
        } header: {
            Text("Bank accounts")
        } footer: {
            Text("DayLedger uses TrueLayer, an FCA-authorised Open Banking provider, for read-only access. Your bank login details never pass through the app.")
        }
    }

    private func connect() {
        Task { await model.connect(using: webAuthenticationSession) }
    }
}
