import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct CodexAccountReconciliationTests {
    @Test
    func `fresh install projects live-only account as visible active and live`() {
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [], activeAccountID: nil)
        let live = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.map(\.email) == ["live@example.com"])
        #expect(projection.activeVisibleAccountID == "live@example.com")
        #expect(projection.liveVisibleAccountID == "live@example.com")
        #expect(projection.switchableAccountIDs.isEmpty)
    }

    @Test
    func `matching live system account does not duplicate stored identity`() {
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "user@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [stored], activeAccountID: stored.id)
        let live = ObservedSystemCodexAccount(
            email: "USER@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.count == 1)
        #expect(projection.activeVisibleAccountID == "user@example.com")
        #expect(projection.liveVisibleAccountID == "user@example.com")
        #expect(projection.switchableAccountIDs == ["user@example.com"])
    }

    @Test
    func `matching live system account becomes active when readable store has no active pointer`() {
        let matched = ManagedCodexAccount(
            id: UUID(),
            email: "match@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let other = ManagedCodexAccount(
            id: UUID(),
            email: "other@example.com",
            managedHomePath: "/tmp/managed-b",
            createdAt: 4,
            updatedAt: 5,
            lastAuthenticatedAt: 6)
        let accounts = ManagedCodexAccountSet(
            version: 1,
            accounts: [matched, other],
            activeAccountID: nil)
        let live = ObservedSystemCodexAccount(
            email: "MATCH@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(Set(projection.visibleAccounts.map(\.email)) == [
            "match@example.com",
            "other@example.com",
        ])
        #expect(projection.activeVisibleAccountID == "match@example.com")
        #expect(projection.liveVisibleAccountID == "match@example.com")
        #expect(Set(projection.switchableAccountIDs) == [
            "match@example.com",
            "other@example.com",
        ])
    }

    @Test
    func `live system account that differs from active stored account remains visible`() {
        let active = ManagedCodexAccount(
            id: UUID(),
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [active], activeAccountID: active.id)
        let live = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(Set(projection.visibleAccounts.map(\.email)) == ["managed@example.com", "system@example.com"])
        #expect(projection.activeVisibleAccountID == "managed@example.com")
        #expect(projection.liveVisibleAccountID == "system@example.com")
        #expect(projection.switchableAccountIDs == ["managed@example.com"])
    }

    @Test
    func `inactive stored account still appears as visible and switchable`() {
        let active = ManagedCodexAccount(
            id: UUID(),
            email: "active@example.com",
            managedHomePath: "/tmp/managed-a",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 3)
        let inactive = ManagedCodexAccount(
            id: UUID(),
            email: "inactive@example.com",
            managedHomePath: "/tmp/managed-b",
            createdAt: 4,
            updatedAt: 5,
            lastAuthenticatedAt: 6)
        let accounts = ManagedCodexAccountSet(
            version: 1,
            accounts: [active, inactive],
            activeAccountID: active.id)
        let live = ObservedSystemCodexAccount(
            email: "system@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(Set(projection.visibleAccounts.map(\.email)) == [
            "active@example.com",
            "inactive@example.com",
            "system@example.com",
        ])
        #expect(projection.activeVisibleAccountID == "active@example.com")
        #expect(projection.liveVisibleAccountID == "system@example.com")
        #expect(Set(projection.switchableAccountIDs) == [
            "active@example.com",
            "inactive@example.com",
        ])
    }

    @Test
    func `unreadable account store still exposes live system account and degraded flag`() {
        let live = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { throw FileManagedCodexAccountStoreError.unsupportedVersion(999) },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.map(\.email) == ["live@example.com"])
        #expect(projection.activeVisibleAccountID == nil)
        #expect(projection.liveVisibleAccountID == "live@example.com")
        #expect(projection.hasUnreadableAddedAccountStore)
        #expect(projection.switchableAccountIDs.isEmpty)
    }

    @Test
    func `whitespace only live email is ignored`() {
        let accounts = ManagedCodexAccountSet(version: 1, accounts: [], activeAccountID: nil)
        let live = ObservedSystemCodexAccount(
            email: "   \n\t  ",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        let reconciler = DefaultCodexAccountReconciler(
            storeLoader: { accounts },
            systemObserver: StubSystemObserver(account: live))

        let projection = reconciler.loadVisibleAccounts(environment: [:])

        #expect(projection.visibleAccounts.isEmpty)
        #expect(projection.activeVisibleAccountID == nil)
        #expect(projection.liveVisibleAccountID == nil)
        #expect(projection.switchableAccountIDs.isEmpty)
    }
}

private struct StubSystemObserver: CodexSystemAccountObserving {
    let account: ObservedSystemCodexAccount?

    func loadSystemAccount(environment _: [String: String]) throws -> ObservedSystemCodexAccount? {
        self.account
    }
}
