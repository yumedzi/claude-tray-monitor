import Foundation

@MainActor
final class Poller {
    private let store: UsageStore
    private var timer: Timer?
    private var isRefreshing = false

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
        isRefreshing = true
        defer { isRefreshing = false }

        var markStale = store.snapshot
        markStale.stale = true
        store.setSnapshot(markStale)

        let env = ProcessInfo.processInfo.environment
        if let override = TokenResolver.detectAuthOverride(env: env) {
            var snapshot = UsageSnapshot()
            snapshot.billingMode = .api
            snapshot.errorMessage = "API billing via \(override)"
            store.setSnapshot(snapshot)
            return
        }

        let candidates = TokenResolver.candidates()
        guard !candidates.isEmpty else {
            var snapshot = UsageSnapshot()
            snapshot.tokenMissing = true
            snapshot.errorMessage = "No Claude Code login found"
            store.setSnapshot(snapshot)
            return
        }

        for candidate in candidates {
            switch await fetch(candidate: candidate) {
            case .success(let snapshot):
                store.setSnapshot(snapshot)
                return
            case .rejected:
                continue
            case .failed(let message):
                var snapshot = store.snapshot
                snapshot.stale = true
                snapshot.errorMessage = message
                snapshot.tokenSource = candidate.source
                store.setSnapshot(snapshot)
                return
            }
        }

        var snapshot = store.snapshot
        snapshot.stale = true
        snapshot.errorMessage = "All stored credentials were rejected"
        snapshot.tokenSource = nil
        store.setSnapshot(snapshot)
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