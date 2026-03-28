import CodexBarCore
import Foundation

extension SettingsStore {
    private enum ManagedCodexAccountStoreState {
        case none
        case active(ManagedCodexAccount)
        case unreadable
    }

    private static func failClosedManagedCodexHomePath(fileManager: FileManager = .default) -> String {
        ManagedCodexHomeFactory.defaultRootURL(fileManager: fileManager)
            .appendingPathComponent("managed-store-unreadable", isDirectory: true)
            .path
    }

    private func managedCodexAccountStoreState() -> ManagedCodexAccountStoreState {
        #if DEBUG
        if CodexManagedRemoteHomeTestingOverride.isUnreadable(for: self) {
            return .unreadable
        }
        if let override = CodexManagedRemoteHomeTestingOverride.account(for: self) {
            return .active(override)
        }
        let store = if let storeURL = CodexManagedRemoteHomeTestingOverride.managedStoreURL(for: self) {
            FileManagedCodexAccountStore(fileURL: storeURL)
        } else {
            FileManagedCodexAccountStore()
        }
        #else
        let store = FileManagedCodexAccountStore()
        #endif

        do {
            let accounts = try store.loadAccounts()
            guard let activeAccountID = accounts.activeAccountID,
                  let account = accounts.account(id: activeAccountID)
            else {
                return .none
            }
            return .active(account)
        } catch {
            return .unreadable
        }
    }

    var activeManagedCodexAccount: ManagedCodexAccount? {
        guard case let .active(account) = self.managedCodexAccountStoreState() else {
            return nil
        }
        return account
    }

    var activeManagedCodexRemoteHomePath: String? {
        #if DEBUG
        if let override = CodexManagedRemoteHomeTestingOverride.homePath(for: self) {
            return override
        }
        #endif

        switch self.managedCodexAccountStoreState() {
        case let .active(account):
            return account.managedHomePath
        case .unreadable:
            return Self.failClosedManagedCodexHomePath()
        case .none:
            return nil
        }
    }

    var activeManagedCodexCookieCacheScope: CookieHeaderCache.Scope? {
        switch self.managedCodexAccountStoreState() {
        case let .active(account):
            .managedAccount(account.id)
        case .unreadable:
            .managedStoreUnreadable
        case .none:
            nil
        }
    }

    var hasUnreadableManagedCodexAccountStore: Bool {
        if case .unreadable = self.managedCodexAccountStoreState() {
            return true
        }
        return false
    }

    var codexUsageDataSource: CodexUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .codex)?.source
            return Self.codexUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .oauth: .oauth
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .codex) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .codex, field: "usageSource", value: newValue.rawValue)
        }
    }

    var codexActiveSource: CodexActiveSource {
        get {
            if let persistedSource = self.providerConfig(for: .codex)?.codexActiveSource {
                return persistedSource
            }
            #if DEBUG
            if CodexManagedRemoteHomeTestingOverride.hasAnyOverride(for: self) {
                return self.overrideBackedDefaultCodexActiveSource()
            }
            #endif
            return self.defaultCodexActiveSource()
        }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.codexActiveSource = newValue
            }
        }
    }

    var codexCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .codex)?.sanitizedCookieHeader ?? "" }
        set {
            // This is intentionally provider-scoped today. A per-managed-account manual cookie override would need
            // its own storage and UI semantics so editing one account's header does not silently rewrite another's.
            self.updateProviderConfig(provider: .codex) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .codex, field: "cookieHeader", value: newValue)
        }
    }

    var codexCookieSource: ProviderCookieSource {
        get {
            let resolved = self.resolvedCookieSource(provider: .codex, fallback: .auto)
            return self.openAIWebAccessEnabled ? resolved : .off
        }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .codex, field: "cookieSource", value: newValue.rawValue)
            self.openAIWebAccessEnabled = newValue.isEnabled
        }
    }

    func ensureCodexCookieLoaded() {}

    private func defaultCodexActiveSource() -> CodexActiveSource {
        if let activeManagedCodexAccount {
            return .managedAccount(id: activeManagedCodexAccount.id)
        }
        return .liveSystem
    }

    #if DEBUG
    private func overrideBackedDefaultCodexActiveSource() -> CodexActiveSource {
        if let override = CodexManagedRemoteHomeTestingOverride.account(for: self) {
            return .managedAccount(id: override.id)
        }
        return .liveSystem
    }
    #endif
}

extension SettingsStore {
    var codexAccountReconciliationSnapshot: CodexAccountReconciliationSnapshot {
        self.codexAccountReconciler().loadSnapshot(environment: self.codexReconciliationEnvironment())
    }

    var codexVisibleAccountProjection: CodexVisibleAccountProjection {
        CodexVisibleAccountProjection.make(from: self.codexAccountReconciliationSnapshot)
    }

    var codexVisibleAccounts: [CodexVisibleAccount] {
        self.codexVisibleAccountProjection.visibleAccounts
    }

    private func codexAccountReconciler() -> DefaultCodexAccountReconciler {
        #if DEBUG
        let liveSystemAccountOverride = CodexManagedRemoteHomeTestingOverride.liveSystemAccount(for: self)
        let reconciliationEnvironmentOverride = CodexManagedRemoteHomeTestingOverride
            .reconciliationEnvironment(for: self)
        let managedAccountOverride = CodexManagedRemoteHomeTestingOverride.account(for: self)
        let unreadableStoreOverride = CodexManagedRemoteHomeTestingOverride.isUnreadable(for: self)
        guard CodexManagedRemoteHomeTestingOverride.hasAnyOverride(for: self) else {
            return DefaultCodexAccountReconciler(activeSource: self.codexActiveSource)
        }

        let storeLoader: @Sendable () throws -> ManagedCodexAccountSet
        if unreadableStoreOverride {
            storeLoader = { throw CodexManagedRemoteHomeTestingOverrideError.unreadableManagedStore }
        } else if let managedAccountOverride {
            let accounts = ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: [managedAccountOverride],
                activeAccountID: managedAccountOverride.id)
            storeLoader = { accounts }
        } else {
            let accounts = ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: [],
                activeAccountID: nil)
            storeLoader = { accounts }
        }

        return DefaultCodexAccountReconciler(
            storeLoader: storeLoader,
            systemObserver: CodexManagedRemoteHomeTestingSystemObserver(
                overrideAccount: liveSystemAccountOverride,
                usesInjectedEnvironment: reconciliationEnvironmentOverride != nil),
            activeSource: self.codexActiveSource)
        #else
        return DefaultCodexAccountReconciler(activeSource: self.codexActiveSource)
        #endif
    }

    private func codexReconciliationEnvironment() -> [String: String] {
        #if DEBUG
        if let override = CodexManagedRemoteHomeTestingOverride.reconciliationEnvironment(for: self) {
            return override
        }
        #endif
        return ProcessInfo.processInfo.environment
    }
}

#if DEBUG
private enum CodexManagedRemoteHomeTestingOverride {
    private struct Override {
        var account: ManagedCodexAccount?
        var homePath: String?
        var unreadableStore: Bool = false
        var managedStoreURL: URL?
        var liveSystemAccount: ObservedSystemCodexAccount?
        var reconciliationEnvironment: [String: String]?

        var isEmpty: Bool {
            self.account == nil && self.homePath == nil && self.unreadableStore == false && self
                .managedStoreURL == nil && self.liveSystemAccount == nil && self
                .reconciliationEnvironment == nil
        }
    }

    @MainActor
    private static var values: [ObjectIdentifier: Override] = [:]

    @MainActor
    private static func store(_ override: Override, for key: ObjectIdentifier) {
        if override.isEmpty {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = override
        }
    }

    @MainActor
    static func account(for settings: SettingsStore) -> ManagedCodexAccount? {
        self.values[ObjectIdentifier(settings)]?.account
    }

    @MainActor
    static func setAccount(_ account: ManagedCodexAccount?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.account = account
        self.store(override, for: key)
    }

    @MainActor
    static func homePath(for settings: SettingsStore) -> String? {
        self.values[ObjectIdentifier(settings)]?.homePath
    }

    @MainActor
    static func setHomePath(_ value: String?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.homePath = value
        self.store(override, for: key)
    }

    @MainActor
    static func isUnreadable(for settings: SettingsStore) -> Bool {
        self.values[ObjectIdentifier(settings)]?.unreadableStore == true
    }

    @MainActor
    static func setUnreadable(_ value: Bool, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.unreadableStore = value
        self.store(override, for: key)
    }

    @MainActor
    static func liveSystemAccount(for settings: SettingsStore) -> ObservedSystemCodexAccount? {
        self.values[ObjectIdentifier(settings)]?.liveSystemAccount
    }

    @MainActor
    static func managedStoreURL(for settings: SettingsStore) -> URL? {
        self.values[ObjectIdentifier(settings)]?.managedStoreURL
    }

    @MainActor
    static func setManagedStoreURL(_ value: URL?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.managedStoreURL = value
        self.store(override, for: key)
    }

    @MainActor
    static func setLiveSystemAccount(_ account: ObservedSystemCodexAccount?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.liveSystemAccount = account
        self.store(override, for: key)
    }

    @MainActor
    static func reconciliationEnvironment(for settings: SettingsStore) -> [String: String]? {
        self.values[ObjectIdentifier(settings)]?.reconciliationEnvironment
    }

    @MainActor
    static func setReconciliationEnvironment(_ environment: [String: String]?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.reconciliationEnvironment = environment
        self.store(override, for: key)
    }

    @MainActor
    static func hasAnyOverride(for settings: SettingsStore) -> Bool {
        self.values[ObjectIdentifier(settings)]?.isEmpty == false
    }
}

private enum CodexManagedRemoteHomeTestingOverrideError: Error {
    case unreadableManagedStore
}

private struct CodexManagedRemoteHomeTestingSystemObserver: CodexSystemAccountObserving {
    let overrideAccount: ObservedSystemCodexAccount?
    let usesInjectedEnvironment: Bool

    func loadSystemAccount(environment: [String: String]) throws -> ObservedSystemCodexAccount? {
        if let overrideAccount {
            return overrideAccount
        }
        guard self.usesInjectedEnvironment else {
            return nil
        }
        return try DefaultCodexSystemAccountObserver().loadSystemAccount(environment: environment)
    }
}

extension SettingsStore {
    var _test_activeManagedCodexRemoteHomePath: String? {
        get { CodexManagedRemoteHomeTestingOverride.homePath(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setHomePath(newValue, for: self) }
    }

    var _test_activeManagedCodexAccount: ManagedCodexAccount? {
        get { CodexManagedRemoteHomeTestingOverride.account(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setAccount(newValue, for: self) }
    }

    var _test_unreadableManagedCodexAccountStore: Bool {
        get { CodexManagedRemoteHomeTestingOverride.isUnreadable(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setUnreadable(newValue, for: self) }
    }

    var _test_managedCodexAccountStoreURL: URL? {
        get { CodexManagedRemoteHomeTestingOverride.managedStoreURL(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setManagedStoreURL(newValue, for: self) }
    }

    var _test_liveSystemCodexAccount: ObservedSystemCodexAccount? {
        get { CodexManagedRemoteHomeTestingOverride.liveSystemAccount(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setLiveSystemAccount(newValue, for: self) }
    }

    var _test_codexReconciliationEnvironment: [String: String]? {
        get { CodexManagedRemoteHomeTestingOverride.reconciliationEnvironment(for: self) }
        set { CodexManagedRemoteHomeTestingOverride.setReconciliationEnvironment(newValue, for: self) }
    }
}
#endif

extension SettingsStore {
    func codexSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.CodexProviderSettings {
        ProviderSettingsSnapshot.CodexProviderSettings(
            usageDataSource: self.codexUsageDataSource,
            cookieSource: self.codexSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.codexSnapshotCookieHeader(tokenOverride: tokenOverride),
            managedAccountStoreUnreadable: self.hasUnreadableManagedCodexAccountStore)
    }

    private static func codexUsageDataSource(from source: ProviderSourceMode?) -> CodexUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web, .api:
            return .auto
        case .cli:
            return .cli
        case .oauth:
            return .oauth
        }
    }

    private func codexSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.codexCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .codex),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .codex,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func codexSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.codexCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .codex),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .codex).isEmpty { return fallback }
        return .manual
    }
}
