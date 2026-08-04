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

        let candidates = TokenResolver.candidates()
        guard !candidates.isEmpty else {
            var snapshot = UsageSnapshot()
            snapshot.tokenMissing = true
            snapshot.errorMessage = "No Claude Code login found"
            store.setSnapshot(snapshot)
            RequestLog.write("refresh skipped: no candidates")
            return
        }

        for candidate in candidates {
            RequestLog.write("trying candidate \(candidate.source)")
            switch await fetch(candidate: candidate) {
            case .success(let snapshot):
                store.setSnapshot(snapshot)
                RequestLog.write("refresh ok via \(candidate.source)")
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
        snapshot.errorMessage = "All stored credentials were rejected"
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
            return .failed("Rate limited (429)")
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