import CodexBarCore
import Foundation

struct CodexVisibleAccount: Equatable, Sendable, Identifiable {
    let id: String
    let email: String
    let storedAccountID: UUID?
    let isActive: Bool
    let isLive: Bool
    let isSwitchable: Bool
    let canReauthenticate: Bool
    let canRemove: Bool
}

struct CodexVisibleAccountProjection: Equatable, Sendable {
    let visibleAccounts: [CodexVisibleAccount]
    let activeVisibleAccountID: String?
    let liveVisibleAccountID: String?
    let switchableAccountIDs: [String]
    let hasUnreadableAddedAccountStore: Bool
}

struct CodexAccountReconciliationSnapshot: Equatable, Sendable {
    let storedAccounts: [ManagedCodexAccount]
    let activeStoredAccount: ManagedCodexAccount?
    let liveSystemAccount: ObservedSystemCodexAccount?
    let matchingStoredAccountForLiveSystemAccount: ManagedCodexAccount?
    let hasUnreadableAddedAccountStore: Bool

    static func == (lhs: CodexAccountReconciliationSnapshot, rhs: CodexAccountReconciliationSnapshot) -> Bool {
        lhs.storedAccounts.map(AccountIdentity.init) == rhs.storedAccounts.map(AccountIdentity.init)
            && lhs.activeStoredAccount.map(AccountIdentity.init) == rhs.activeStoredAccount.map(AccountIdentity.init)
            && lhs.liveSystemAccount == rhs.liveSystemAccount
            && lhs.matchingStoredAccountForLiveSystemAccount.map(AccountIdentity.init)
            == rhs.matchingStoredAccountForLiveSystemAccount.map(AccountIdentity.init)
            && lhs.hasUnreadableAddedAccountStore == rhs.hasUnreadableAddedAccountStore
    }
}

struct DefaultCodexAccountReconciler {
    let storeLoader: @Sendable () throws -> ManagedCodexAccountSet
    let systemObserver: any CodexSystemAccountObserving

    init(
        storeLoader: @escaping @Sendable () throws -> ManagedCodexAccountSet = {
            try FileManagedCodexAccountStore().loadAccounts()
        },
        systemObserver: any CodexSystemAccountObserving = DefaultCodexSystemAccountObserver())
    {
        self.storeLoader = storeLoader
        self.systemObserver = systemObserver
    }

    func loadSnapshot(environment: [String: String]) -> CodexAccountReconciliationSnapshot {
        let liveSystemAccount = self.loadLiveSystemAccount(environment: environment)

        do {
            let accounts = try self.storeLoader()
            let activeStoredAccount = accounts.activeAccountID.flatMap { accounts.account(id: $0) }
            let matchingStoredAccountForLiveSystemAccount = liveSystemAccount.flatMap {
                accounts.account(email: $0.email)
            }

            return CodexAccountReconciliationSnapshot(
                storedAccounts: accounts.accounts,
                activeStoredAccount: activeStoredAccount,
                liveSystemAccount: liveSystemAccount,
                matchingStoredAccountForLiveSystemAccount: matchingStoredAccountForLiveSystemAccount,
                hasUnreadableAddedAccountStore: false)
        } catch {
            return CodexAccountReconciliationSnapshot(
                storedAccounts: [],
                activeStoredAccount: nil,
                liveSystemAccount: liveSystemAccount,
                matchingStoredAccountForLiveSystemAccount: nil,
                hasUnreadableAddedAccountStore: true)
        }
    }

    func loadVisibleAccounts(environment: [String: String]) -> CodexVisibleAccountProjection {
        CodexVisibleAccountProjection.make(from: self.loadSnapshot(environment: environment))
    }

    private func loadLiveSystemAccount(environment: [String: String]) -> ObservedSystemCodexAccount? {
        do {
            guard let account = try self.systemObserver.loadSystemAccount(environment: environment) else {
                return nil
            }
            let normalizedEmail = Self.normalizeEmail(account.email)
            guard !normalizedEmail.isEmpty else {
                return nil
            }
            return ObservedSystemCodexAccount(
                email: normalizedEmail,
                codexHomePath: account.codexHomePath,
                observedAt: account.observedAt)
        } catch {
            return nil
        }
    }

    private static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension CodexVisibleAccountProjection {
    static func make(from snapshot: CodexAccountReconciliationSnapshot) -> CodexVisibleAccountProjection {
        var visibleByEmail: [String: CodexVisibleAccount] = [:]
        let canInferLiveOnlyActiveAccount = snapshot.storedAccounts.isEmpty && !snapshot.hasUnreadableAddedAccountStore
        let canRecoverMatchedLiveAsActive = !snapshot.hasUnreadableAddedAccountStore
            && !snapshot.storedAccounts.isEmpty
            && snapshot.activeStoredAccount == nil
            && snapshot.matchingStoredAccountForLiveSystemAccount != nil

        for storedAccount in snapshot.storedAccounts {
            visibleByEmail[storedAccount.email] = CodexVisibleAccount(
                id: storedAccount.email,
                email: storedAccount.email,
                storedAccountID: storedAccount.id,
                isActive: storedAccount.id == snapshot.activeStoredAccount?.id,
                isLive: false,
                isSwitchable: true,
                canReauthenticate: true,
                canRemove: true)
        }

        if let liveSystemAccount = snapshot.liveSystemAccount {
            let matchingStoredAccount = snapshot.matchingStoredAccountForLiveSystemAccount
            let existing = visibleByEmail[liveSystemAccount.email]
            let isRecoveredActiveMatch = canRecoverMatchedLiveAsActive
                && matchingStoredAccount?.email == liveSystemAccount.email

            visibleByEmail[liveSystemAccount.email] = CodexVisibleAccount(
                id: liveSystemAccount.email,
                email: liveSystemAccount.email,
                storedAccountID: existing?.storedAccountID ?? matchingStoredAccount?.id,
                isActive: (existing?.isActive ?? false) || isRecoveredActiveMatch || canInferLiveOnlyActiveAccount,
                isLive: true,
                isSwitchable: existing?.isSwitchable ?? (matchingStoredAccount != nil),
                canReauthenticate: true,
                canRemove: existing?.canRemove ?? (matchingStoredAccount != nil))
        }

        let visibleAccounts = visibleByEmail.values.sorted { lhs, rhs in
            lhs.email < rhs.email
        }

        return CodexVisibleAccountProjection(
            visibleAccounts: visibleAccounts,
            activeVisibleAccountID: visibleAccounts.first { $0.isActive }?.id,
            liveVisibleAccountID: visibleAccounts.first { $0.isLive }?.id,
            switchableAccountIDs: visibleAccounts.filter(\.isSwitchable).map(\.id),
            hasUnreadableAddedAccountStore: snapshot.hasUnreadableAddedAccountStore)
    }
}

private struct AccountIdentity: Equatable {
    let id: UUID
    let email: String
    let managedHomePath: String
    let createdAt: TimeInterval
    let updatedAt: TimeInterval
    let lastAuthenticatedAt: TimeInterval?

    init(_ account: ManagedCodexAccount) {
        self.id = account.id
        self.email = account.email
        self.managedHomePath = account.managedHomePath
        self.createdAt = account.createdAt
        self.updatedAt = account.updatedAt
        self.lastAuthenticatedAt = account.lastAuthenticatedAt
    }
}
