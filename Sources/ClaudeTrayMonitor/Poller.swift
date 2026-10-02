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

    private var pendingForcedRefresh = false

    /// Account selection changed: refresh now, even inside the throttle window or mid-refresh.
    func refreshForSelectionChange() async {
        lastRefreshAt = nil
        if isRefreshing {
            pendingForcedRefresh = true
            return
        }
        await refresh(force: true)
    }

    func refresh(force: Bool) async {
        guard !isRefreshing else { return }
        if let last = lastRefreshAt, abs(Date().timeIntervalSince(last)) < Self.minRefreshGap {
            return
        }
        await performRefresh(force: force)
        if pendingForcedRefresh {
            pendingForcedRefresh = false
            lastRefreshAt = nil
            await performRefresh(force: true)
        }
    }

    private func performRefresh(force: Bool) async {
        lastRefreshAt = Date()
        isRefreshing = true
        defer { isRefreshing = false }
        store.setRefreshing(true)
        defer { store.setRefreshing(false) }

        let selection = AccountSelection.current
        RequestLog.write("refresh start (force=\(force), account=\(selection.id))")
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

        if case let .pinned(profileDir, organizationId) = selection {
            await refreshPinned(profileDir: profileDir, organizationId: organizationId)
            return
        }

        let desktopSession = selection == .oauth ? nil : await DesktopSession.activeSession()
        var desktopFailure: String?

        if let session = desktopSession {
            RequestLog.write("claude desktop session found (\(session.profileDir))")
            switch await fetch(claudeSession: session, organizationId: nil) {
            case .success(let snapshot):
                await finishDesktop(snapshot)
                return
            case .rejected:
                RequestLog.write("claude desktop session rejected")
            case .failed(let message):
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
            case .success(var snapshot):
                if selection == .oauth {
                    snapshot.accountId = AccountSelection.oauthId
                    snapshot.accountLabel = AppSettings.accountNames[AccountSelection.oauthId] ?? "Claude Code login"
                }
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

    /// A pinned account never falls back to another login — showing the wrong account is worse than an error.
    private func refreshPinned(profileDir: String, organizationId: String?) async {
        let name = (profileDir as NSString).lastPathComponent
        guard let session = await DesktopSession.session(forProfileDir: profileDir) else {
            failPinned("Selected account unavailable\nNo Claude Desktop session in \(name)")
            return
        }
        RequestLog.write("pinned desktop session \(profileDir) org=\(organizationId ?? "default")")
        switch await fetch(claudeSession: session, organizationId: organizationId) {
        case .success(let snapshot):
            await finishDesktop(snapshot)
        case .rejected:
            failPinned("Selected account unavailable\nSession in \(name) was rejected — sign in to Claude Desktop again")
        case .failed(let message):
            failPinned(message)
        }
    }

    private func failPinned(_ message: String) {
        var snapshot = UsageSnapshot()
        snapshot.errorMessage = message
        snapshot.stale = true
        store.setSnapshot(snapshot)
        RequestLog.write("refresh failed (pinned): \(message.replacingOccurrences(of: "\n", with: " — "))")
    }

    private func finishDesktop(_ snapshot: UsageSnapshot) async {
        var result = snapshot
        if result.planLabel == nil {
            result.planLabel = DesktopSession.runningPlanLabel() ?? TokenResolver.quickPlanLabel()
        }
        if result.planLabel == "Enterprise", result.spend?.fromExtraUsage == true {
            result.spend = nil
        }
        if result.spend == nil, result.planLabel == "Enterprise" {
            let probed = await spendFromCandidates()
            if let spend = probed.spend {
                result.spend = spend
                RequestLog.write("monthly spend via \(probed.source ?? "unknown")")
            }
        }
        store.setSnapshot(result)
        RequestLog.write("refresh ok via Claude Desktop session (account: \(result.accountLabel ?? "?"), plan: \(result.planLabel ?? "unknown"))")
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

    private func spendFromCandidates() async -> (spend: SpendInfo?, source: String?) {
        let candidates = await TokenResolver.candidatesAsync()
        for candidate in candidates {
            let (result, _) = await fetchWithRefresh(candidate)
            if case .success(let snapshot) = result, let spend = snapshot.spend {
                return (spend, snapshot.tokenSource ?? candidate.source)
            }
        }
        return (nil, nil)
    }

    private func fetch(claudeSession: DesktopSession.Session, organizationId: String?) async -> FetchResult {
        do {
            let usage = try await DesktopSession.fetchUsage(session: claudeSession, organizationId: organizationId)
            var snapshot = UsageSnapshot()
            snapshot.windows = UsageParser.parseUsage(usage.json)
            snapshot.spend = UsageParser.parseSpend(usage.json)
            guard !snapshot.windows.isEmpty || snapshot.spend != nil else { return .failed("no usage data (web)") }
            snapshot.billingMode = .subscription
            snapshot.planLabel = DesktopSession.planLabel(forBillingType: usage.organization.billingType)
            snapshot.accountId = AccountSelection.pinned(profileDir: claudeSession.profileDir, organizationId: usage.organization.id).id
            snapshot.accountLabel = AccountSelection.displayName(
                profileDir: claudeSession.profileDir,
                organizationId: usage.organization.id,
                fallback: usage.organization.name
            )
            snapshot.fetchedAt = Date()
            snapshot.stale = false
            snapshot.tokenSource = "Claude Desktop (\((claudeSession.profileDir as NSString).lastPathComponent))"
            return .success(snapshot)
        } catch APIError.tokenRejected {
            return .rejected
        } catch APIError.rateLimited {
            RequestLog.write("rate limited 429 via Claude Desktop session")
            return .failed("No active Claude session detected\nRate limited (429)")
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
            snapshot.spend = UsageParser.parseSpend(usageJSON)
            snapshot.billingMode = .subscription
            snapshot.planLabel = UsageParser.parseProfile(profileJSON, tokenSubscriptionType: candidate.subscriptionType)
            if snapshot.planLabel == "Enterprise", snapshot.spend?.fromExtraUsage == true {
                snapshot.spend = nil
            }
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