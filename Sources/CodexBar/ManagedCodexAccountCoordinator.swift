import CodexBarCore
import Foundation
import Observation

enum ManagedCodexAccountCoordinatorError: Error, Equatable, Sendable {
    case authenticationInProgress
}

@MainActor
@Observable
final class ManagedCodexAccountCoordinator {
    let service: ManagedCodexAccountService
    private(set) var isAuthenticatingManagedAccount: Bool = false
    private(set) var authenticatingManagedAccountID: UUID?

    init(service: ManagedCodexAccountService = ManagedCodexAccountService()) {
        self.service = service
    }

    func authenticateManagedAccount(
        existingAccountID: UUID? = nil,
        timeout: TimeInterval = 120)
        async throws -> ManagedCodexAccount
    {
        guard self.isAuthenticatingManagedAccount == false else {
            throw ManagedCodexAccountCoordinatorError.authenticationInProgress
        }

        self.isAuthenticatingManagedAccount = true
        self.authenticatingManagedAccountID = existingAccountID
        defer {
            self.isAuthenticatingManagedAccount = false
            self.authenticatingManagedAccountID = nil
        }

        return try await self.service.authenticateManagedAccount(
            existingAccountID: existingAccountID,
            timeout: timeout)
    }

    func removeManagedAccount(id: UUID) async throws {
        try await self.service.removeManagedAccount(id: id)
    }
}
