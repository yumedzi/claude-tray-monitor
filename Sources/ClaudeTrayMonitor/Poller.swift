import Foundation

@MainActor
final class Poller {
    private let store: UsageStore
    private var timer: Timer?
    private var isRefreshing = false
    private var lastRefreshAt: Date?

    private static let minRefreshGap: TimeInterval = 10
    private static let interRequestGap: UInt64 = 700_000_000
    private static let candidateRetryGap: UInt64 = 700_000_000

    init(store: UsageStore) {
        self.store = store
    }

    func start() {
        schedule(intervalMinutes: AppSettings.pollIntervalMinutes)
    }

    func reschedule(intervalMinutes: Double) {
        timer?.invalidate()
        timer = nil
        schedule(intervalMinutes: intervalMinutes)
    }

    func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        if let last = lastRefreshAt, abs(Date().timeIntervalSince(last)) < Self.minRefreshGap {
            return
        }
        lastRefreshAt = Date()
        isRefreshing = true
        defer { isRefreshing = false }
        store.setRefreshing(true)
        defer { store.setRefreshing(false) }

        RequestLog.write("refresh start (force=\(force))")
        var markStale = store.snapshot
        markStale.stale = true
        store.setSnapshot(markStale)

        let env = ProcessInfo.processInfo.environment
        if let override = TokenResolver.detectAuthOverride(env: env) {
            var snapshot = UsageSnapshot()
            snapshot.billingMode = .api
            snapshot.errorMessage = "API billing via \(override)"
            store.setSnapshot(snapshot)
            RequestLog.write("refresh skipped: API billing via \(override)")
            return
        }

        let desktopSession = await DesktopSession.activeSession()
        var desktopFailure: String?

        if let session = desktopSession {
            RequestLog.write("claude desktop session found")
            switch await fetch(claudeSession: session) {
            case (let .success(snapshot), let billingType):
                var result = snapshot
                result.planLabel = DesktopSession.planLabel(forBillingType: billingType)
                    ?? DesktopSession.runningPlanLabel()
                    ?? TokenResolver.quickPlanLabel()
                store.setSnapshot(result)
                RequestLog.write("refresh ok via Claude Desktop session (plan: \(result.planLabel ?? "unknown"))")
                return
            case (let .rejected, _):
                RequestLog.write("claude desktop session rejected")
            case (let .failed(message), _):
                desktopFailure = message
                RequestLog.write("claude desktop session failed: \(message)")
            }
        }

        let candidates = await TokenResolver.candidatesAsync()

        guard !candidates.isEmpty else {
            var snapshot = UsageSnapshot()
            if let desktopFailure {
                snapshot.tokenMissing = false
                snapshot.errorMessage = desktopFailure
            } else {
                snapshot.tokenMissing = true
                snapshot.errorMessage = "No Claude Code login found"
            }
            store.setSnapshot(snapshot)
            RequestLog.write("refresh skipped: no candidates")
            return
        }

        for candidate in candidates {
            RequestLog.write("trying candidate \(candidate.source)")
            let (result, refreshed) = await fetchWithRefresh(candidate)
            switch result {
            case .success(let snapshot):
                store.setSnapshot(snapshot)
                RequestLog.write(refreshed ? "refresh ok via \(candidate.source) (refreshed)" : "refresh ok via \(candidate.source)")
                return
            case .rejected:
                RequestLog.write("candidate rejected: \(candidate.source)")
                try? await Task.sleep(nanoseconds: Self.candidateRetryGap)
                continue
            case .failed(let message):
                var snapshot = store.snapshot
                snapshot.stale = true
                snapshot.errorMessage = message
                snapshot.tokenSource = candidate.source
                store.setSnapshot(snapshot)
                RequestLog.write("refresh failed: \(message)")
                return
            }
        }

        var snapshot = store.snapshot
        snapshot.stale = true
        snapshot.errorMessage = desktopFailure ?? "All stored credentials were rejected"
        snapshot.tokenSource = nil
        store.setSnapshot(snapshot)
        RequestLog.write("refresh failed: all credentials rejected")
    }

    private func schedule(intervalMinutes: Double) {
        let interval = max(1, intervalMinutes) * 60
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh(force: false)
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fetchWithRefresh(_ candidate: TokenCandidate) async -> (FetchResult, didRefresh: Bool) {
        let initial = await fetch(candidate: candidate)
        guard case .rejected = initial, let refreshToken = candidate.refreshToken else {
            return (initial, false)
        }
        RequestLog.write("refresh token for \(candidate.source)")
        do {
            let oauth = try await OAuthRefresher.refresh(refreshToken: refreshToken)
            TokenResolver.writeBackRotatedTokens(
                for: candidate,
                accessToken: oauth.accessToken,
                refreshToken: oauth.refreshToken,
                expiresAt: oauth.expiresAt
            )
            let fresh = candidate.refreshed(
                accessToken: oauth.accessToken,
                refreshToken: oauth.refreshToken ?? refreshToken,
                expiresAt: oauth.expiresAt
            )
            try? await Task.sleep(nanoseconds: Self.interRequestGap)
            let retried = await fetch(candidate: fresh)
            if case .success = retried {
                return (retried, true)
            }
            RequestLog.write("retry after refresh failed for \(candidate.source)")
            return (retried, false)
        } catch APIError.rateLimited {
            RequestLog.write("token refresh rate limited for \(candidate.source)")
            return (.failed("Token refresh rate limited (429)"), false)
        } catch {
            RequestLog.write("refresh failed for \(candidate.source): \(error.localizedDescription)")
            return (initial, false)
        }
    }

    private func fetch(claudeSession: DesktopSession.Session) async -> (FetchResult, billingType: String?) {
        do {
            let (usageJSON, billingType) = try await DesktopSession.fetchUsage(session: claudeSession)
            var snapshot = UsageSnapshot()
            snapshot.windows = UsageParser.parseUsage(usageJSON)
            guard !snapshot.windows.isEmpty else { return (.failed("no usage data (web)"), nil) }
            snapshot.billingMode = .subscription
            snapshot.fetchedAt = Date()
            snapshot.stale = false
            snapshot.tokenSource = "Claude Desktop session"
            return (.success(snapshot), billingType)
        } catch APIError.tokenRejected {
            return (.rejected, nil)
        } catch APIError.rateLimited {
            RequestLog.write("rate limited 429 via Claude Desktop session")
            return (.failed("No active Claude session detected\nRate limited (429)"), nil)
        } catch APIError.server(let code) {
            return (.failed("Server error \(code)"), nil)
        } catch APIError.http(let code) {
            return (.failed("HTTP \(code)"), nil)
        } catch APIError.network(let message) {
            return (.failed("Network: \(message)"), nil)
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
    }

    private func fetch(candidate: TokenCandidate) async -> FetchResult {
        do {
            let usageJSON: [String: Any]?
            do {
                usageJSON = try await UsageAPI.getJSON(UsageAPI.usageURL, token: candidate.token)
            } catch {
                throw error
            }

            if usageJSON != nil {
                try? await Task.sleep(nanoseconds: Self.interRequestGap)
            }
            let profileJSON = (try? await UsageAPI.getJSON(UsageAPI.profileURL, token: candidate.token)) ?? [:]

            guard let usageJSON else { return .failed("no usage data") }
            var snapshot = UsageSnapshot()
            snapshot.windows = UsageParser.parseUsage(usageJSON)
            snapshot.billingMode = .subscription
            snapshot.planLabel = UsageParser.parseProfile(profileJSON, tokenSubscriptionType: candidate.subscriptionType)
            snapshot.fetchedAt = Date()
            snapshot.stale = false
            snapshot.tokenSource = candidate.source
            return .success(snapshot)
        } catch APIError.tokenRejected {
            return .rejected
        } catch APIError.rateLimited {
            RequestLog.write("rate limited 429 via \(candidate.source)")
            return .failed("No active Claude Code session detected\nRate limited (429)")
        } catch APIError.server(let code) {
            return .failed("Server error \(code)")
        } catch APIError.http(let code) {
            return .failed("HTTP \(code)")
        } catch APIError.network(let message) {
            return .failed("Network: \(message)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

private enum FetchResult {
    case success(UsageSnapshot)
    case rejected
    case failed(String)
}