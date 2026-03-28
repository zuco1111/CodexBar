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
        #endif

        do {
            let accounts = try FileManagedCodexAccountStore().loadAccounts()
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

    var codexCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .codex)?.sanitizedCookieHeader ?? "" }
        set {
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
}

#if DEBUG
private enum CodexManagedRemoteHomeTestingOverride {
    private struct Override {
        var account: ManagedCodexAccount?
        var homePath: String?
        var unreadableStore: Bool = false
    }

    @MainActor
    private static var values: [ObjectIdentifier: Override] = [:]

    @MainActor
    static func account(for settings: SettingsStore) -> ManagedCodexAccount? {
        self.values[ObjectIdentifier(settings)]?.account
    }

    @MainActor
    static func setAccount(_ account: ManagedCodexAccount?, for settings: SettingsStore) {
        let key = ObjectIdentifier(settings)
        var override = self.values[key] ?? Override()
        override.account = account
        if override.account == nil, override.homePath == nil, !override.unreadableStore {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = override
        }
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
        if override.account == nil, override.homePath == nil, !override.unreadableStore {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = override
        }
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
        if override.account == nil, override.homePath == nil, !override.unreadableStore {
            self.values.removeValue(forKey: key)
        } else {
            self.values[key] = override
        }
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
}
#endif

extension SettingsStore {
    func codexSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.CodexProviderSettings {
        ProviderSettingsSnapshot.CodexProviderSettings(
            usageDataSource: self.codexUsageDataSource,
            cookieSource: self.codexSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.codexSnapshotCookieHeader(tokenOverride: tokenOverride))
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
