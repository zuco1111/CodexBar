import Foundation

struct OpenAIWebRefreshGateContext {
    let force: Bool
    let accountDidChange: Bool
    let lastError: String?
    let lastSnapshotAt: Date?
    let lastAttemptAt: Date?
    let now: Date
    let refreshInterval: TimeInterval
}

struct OpenAIWebRefreshPolicyContext {
    let accessEnabled: Bool
    let batterySaverEnabled: Bool
    let force: Bool
}

// MARK: - OpenAI web error messaging

extension UsageStore {
    nonisolated static func shouldRunOpenAIWebRefresh(_ context: OpenAIWebRefreshPolicyContext) -> Bool {
        guard context.accessEnabled else { return false }
        return context.force || !context.batterySaverEnabled
    }

    nonisolated static func forceOpenAIWebRefreshForStaleRequest(batterySaverEnabled: Bool) -> Bool {
        !batterySaverEnabled
    }

    nonisolated static func shouldSkipOpenAIWebRefresh(_ context: OpenAIWebRefreshGateContext) -> Bool {
        if context.force || context.accountDidChange { return false }
        if let lastAttemptAt = context.lastAttemptAt,
           context.now.timeIntervalSince(lastAttemptAt) < context.refreshInterval
        {
            return true
        }
        if context.lastError == nil,
           let lastSnapshotAt = context.lastSnapshotAt,
           context.now.timeIntervalSince(lastSnapshotAt) < context.refreshInterval
        {
            return true
        }
        return false
    }

    func syncOpenAIWebState() {
        guard self.isEnabled(.codex),
              self.settings.openAIWebAccessEnabled,
              self.settings.codexCookieSource.isEnabled
        else {
            self.resetOpenAIWebState()
            return
        }

        let targetEmail = self.codexAccountEmailForOpenAIDashboard()
        self.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: targetEmail)
    }

    func dashboardEmailMismatch(expected: String?, actual: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return false }
        guard let raw = actual?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        return raw.lowercased() != expected.lowercased()
    }

    func codexAccountEmailForOpenAIDashboard() -> String? {
        let direct = self.snapshots[.codex]?.accountEmail(for: .codex)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct, !direct.isEmpty { return direct }
        let fallback = self.codexFetcher.loadAccountInfo().email?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fallback, !fallback.isEmpty { return fallback }
        let cached = self.openAIDashboard?.signedInEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached, !cached.isEmpty { return cached }
        let imported = self.lastOpenAIDashboardCookieImportEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let imported, !imported.isEmpty { return imported }
        return nil
    }

    func openAIDashboardFriendlyError(
        body: String,
        targetEmail: String?,
        cookieImportStatus: String?) -> String?
    {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = cookieImportStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return [
                "OpenAI web dashboard returned an empty page.",
                "Sign in to chatgpt.com and update OpenAI cookies in Providers → Codex.",
            ].joined(separator: " ")
        }

        let lower = trimmed.lowercased()
        let looksLikePublicLanding = lower.contains("skip to content")
            && (lower.contains("about") || lower.contains("openai") || lower.contains("chatgpt"))
        let looksLoggedOut = lower.contains("sign in")
            || lower.contains("log in")
            || lower.contains("create account")
            || lower.contains("continue with google")
            || lower.contains("continue with apple")
            || lower.contains("continue with microsoft")

        guard looksLikePublicLanding || looksLoggedOut else { return nil }
        let emailLabel = targetEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLabel = (emailLabel?.isEmpty == false) ? emailLabel! : "your OpenAI account"
        if let status, !status.isEmpty {
            if status.contains("cookies do not match Codex account")
                || status.localizedCaseInsensitiveContains("cookie import failed")
            {
                return [
                    status,
                    "Sign in to chatgpt.com as \(targetLabel), then update OpenAI cookies in Providers → Codex.",
                ].joined(separator: " ")
            }
        }
        return [
            "OpenAI web dashboard returned a public page (not signed in).",
            "Sign in to chatgpt.com as \(targetLabel), then update OpenAI cookies in Providers → Codex.",
        ].joined(separator: " ")
    }
}
