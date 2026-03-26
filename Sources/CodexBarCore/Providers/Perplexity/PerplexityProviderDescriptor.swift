import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum PerplexityProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .perplexity,
            metadata: ProviderMetadata(
                id: .perplexity,
                displayName: "Perplexity",
                sessionLabel: "Credits",
                weeklyLabel: "Bonus credits",
                opusLabel: "Purchased",
                supportsOpus: true,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Perplexity usage",
                cliName: "perplexity",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://www.perplexity.ai/account/usage",
                statusPageURL: nil,
                statusLinkURL: "https://status.perplexity.com/"),
            branding: ProviderBranding(
                iconStyle: .perplexity,
                iconResourceName: "ProviderIcon-perplexity",
                color: ProviderColor(red: 32 / 255, green: 178 / 255, blue: 170 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Perplexity cost tracking is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [PerplexityWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "perplexity",
                aliases: [],
                versionDetector: nil))
    }
}

struct PerplexityWebFetchStrategy: ProviderFetchStrategy {
    private enum SessionCookieSource {
        case manual
        case cache
        case browser
        case environment

        var shouldCacheAfterFetch: Bool {
            self == .browser
        }
    }

    private struct ResolvedSessionCookie {
        let value: PerplexityCookieOverride
        let source: SessionCookieSource
    }

    private struct SessionFetchResult {
        let snapshot: PerplexityUsageSnapshot
        let cookie: PerplexityCookieOverride
    }

    let id: String = "perplexity.web"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        guard context.settings?.perplexity?.cookieSource != .off else { return false }
        if context.settings?.perplexity?.cookieSource == .manual { return true }

        // Priority order mirrors resolveSessionCookie: manual override → cache → browser import → env var
        if PerplexityCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        if CookieHeaderCache.load(provider: .perplexity) != nil {
            return true
        }

        #if os(macOS)
        if context.settings?.perplexity?.cookieSource != .off {
            if PerplexityCookieImporter.hasSession() { return true }
        }
        #endif

        if PerplexitySettingsReader.sessionToken(environment: context.env) != nil {
            return true
        }

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let resolvedCookie = try self.resolveSessionCookie(context: context) else {
            throw PerplexityAPIError.missingToken
        }
        do {
            let result = try await self.fetchSnapshot(using: resolvedCookie)
            self.cacheSessionCookieIfNeeded(resolvedCookie, usedCookie: result.cookie, sourceLabel: "web")
            return self.makeResult(
                usage: result.snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        } catch PerplexityAPIError.invalidToken {
            // Clear stale cache and retry once with a fresh browser import
            CookieHeaderCache.clear(provider: .perplexity)
            PerplexityCookieImporter.invalidateImportSessionCache()
            let preferEnvironment = resolvedCookie.source == .browser || resolvedCookie.source == .cache
            guard let freshCookie = try self.resolveSessionCookieSkippingCache(
                context: context,
                preferEnvironment: preferEnvironment),
                !self.isEquivalentCookie(freshCookie.value, resolvedCookie.value)
            else {
                throw PerplexityAPIError.invalidToken
            }
            let result = try await self.fetchSnapshot(using: freshCookie)
            self.cacheSessionCookieIfNeeded(freshCookie, usedCookie: result.cookie, sourceLabel: "web (retry)")
            return self.makeResult(
                usage: result.snapshot.toUsageSnapshot(),
                sourceLabel: "web")
        }
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case PerplexityAPIError.missingToken = error { return false }
        if case PerplexityAPIError.invalidCookie = error { return false }
        if case PerplexityAPIError.invalidToken = error { return false }
        return true
    }

    private func resolveSessionCookie(context: ProviderFetchContext) throws -> ResolvedSessionCookie? {
        guard context.settings?.perplexity?.cookieSource != .off else { return nil }

        if context.settings?.perplexity?.cookieSource == .manual {
            guard let override = PerplexityCookieHeader.resolveCookieOverride(context: context) else {
                throw PerplexityAPIError.invalidCookie
            }
            return ResolvedSessionCookie(value: override, source: .manual)
        }

        // Try cached cookie before expensive browser import
        if let cached = CookieHeaderCache.load(provider: .perplexity) {
            if let override = PerplexityCookieHeader.override(from: cached.cookieHeader) {
                return ResolvedSessionCookie(value: override, source: .cache)
            }
        }

        return self.resolveSessionCookieFromBrowserOrEnv(context: context)
    }

    /// Resolves a session cookie without consulting the cache (used for retry after invalidToken).
    private func resolveSessionCookieSkippingCache(
        context: ProviderFetchContext,
        preferEnvironment: Bool = false) throws -> ResolvedSessionCookie?
    {
        guard context.settings?.perplexity?.cookieSource != .off else { return nil }

        if context.settings?.perplexity?.cookieSource == .manual {
            guard let override = PerplexityCookieHeader.resolveCookieOverride(context: context) else {
                throw PerplexityAPIError.invalidCookie
            }
            return ResolvedSessionCookie(value: override, source: .manual)
        }
        return self.resolveSessionCookieFromBrowserOrEnv(
            context: context,
            preferEnvironment: preferEnvironment)
    }

    private func resolveSessionCookieFromBrowserOrEnv(
        context: ProviderFetchContext,
        preferEnvironment: Bool = false) -> ResolvedSessionCookie?
    {
        guard context.settings?.perplexity?.cookieSource != .off else { return nil }

        if preferEnvironment,
           let cookie = PerplexitySettingsReader.sessionCookieOverride(environment: context.env)
        {
            return ResolvedSessionCookie(value: cookie, source: .environment)
        }

        // Try browser cookie import when auto mode is enabled
        #if os(macOS)
        do {
            let session = try PerplexityCookieImporter.importSession()
            if let cookie = session.sessionCookie {
                return ResolvedSessionCookie(value: cookie, source: .browser)
            }
        } catch {
            // No browser cookies found
        }
        #endif

        // Fall back to environment
        if let cookie = PerplexitySettingsReader.sessionCookieOverride(environment: context.env) {
            return ResolvedSessionCookie(value: cookie, source: .environment)
        }
        return nil
    }

    private func cacheSessionCookieIfNeeded(
        _ cookie: ResolvedSessionCookie,
        usedCookie: PerplexityCookieOverride,
        sourceLabel: String)
    {
        guard cookie.source.shouldCacheAfterFetch else { return }
        CookieHeaderCache.store(
            provider: .perplexity,
            cookieHeader: "\(usedCookie.name)=\(usedCookie.token)",
            sourceLabel: sourceLabel)
    }

    private func fetchSnapshot(using cookie: ResolvedSessionCookie) async throws -> SessionFetchResult {
        var lastInvalidToken = false
        for cookieName in cookie.value.requestCookieNames {
            do {
                let snapshot = try await PerplexityUsageFetcher.fetchCredits(
                    sessionToken: cookie.value.token,
                    cookieName: cookieName)
                return SessionFetchResult(
                    snapshot: snapshot,
                    cookie: PerplexityCookieOverride(name: cookieName, token: cookie.value.token))
            } catch PerplexityAPIError.invalidToken {
                lastInvalidToken = true
                continue
            }
        }

        if lastInvalidToken {
            throw PerplexityAPIError.invalidToken
        }
        throw PerplexityAPIError.missingToken
    }

    private func isEquivalentCookie(_ lhs: PerplexityCookieOverride, _ rhs: PerplexityCookieOverride) -> Bool {
        lhs.token == rhs.token && lhs.requestCookieNames == rhs.requestCookieNames
    }
}
