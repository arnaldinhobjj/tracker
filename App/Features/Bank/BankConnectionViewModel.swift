import AuthenticationServices
import BankKit
import Foundation
import Observation
import SwiftUI

/// Drives the "Connect a bank" flow through TrueLayer's hosted bank picker.
@MainActor
@Observable
final class BankConnectionViewModel {
    private(set) var connections: [BankConnection] = []
    private(set) var isConnecting = false
    var error: UserFacingError?

    private let bank: BankService
    private let sync: TransactionSyncService

    init(bank: BankService, sync: TransactionSyncService) {
        self.bank = bank
        self.sync = sync
        reload()
    }

    var isConfigured: Bool { bank.isConfigured }

    func reload() {
        connections = bank.connections()
    }

    func connect(using session: WebAuthenticationSession) async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            let request = try bank.makeAuthorizationRequest()
            let callbackURL = try await session.authenticate(
                using: request.url,
                callbackURLScheme: request.callbackURLScheme,
                preferredBrowserSession: .ephemeral
            )
            _ = try await bank.completeAuthorization(callbackURL: callbackURL, request: request)
            error = nil
            reload()
            _ = await sync.sync()
        } catch let authError as ASWebAuthenticationSessionError where authError.code == .canceledLogin {
            // User closed the sheet; nothing to report.
        } catch {
            self.error = UserFacingError(error)
        }
        reload()
    }

    func disconnect(_ connection: BankConnection) async {
        await bank.disconnect(connectionID: connection.id)
        reload()
    }
}
