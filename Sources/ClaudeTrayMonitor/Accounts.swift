import Foundation
import Combine

/// Which account the tray reports on. Persisted as a string in `AppSettings.selectedAccountId`.
enum AccountSelection: Equatable {
    case auto
    case oauth
    case pinned(profileDir: String, organizationId: String?)

    static let autoId = "auto"
    static let oauthId = "oauth"

    init(id: String) {
        switch id {
        case Self.autoId, "": self = .auto
        case Self.oauthId: self = .oauth
        default:
            let parts = id.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let org = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            self = .pinned(profileDir: parts[0], organizationId: org)
        }
    }

    var id: String {
        switch self {
        case .auto: return Self.autoId
        case .oauth: return Self.oauthId
        case let .pinned(dir, org): return "\(dir)|\(org ?? "")"
        }
    }

    static var current: AccountSelection { AccountSelection(id: AppSettings.selectedAccountId) }

    /// Pinned ids may omit the org (migrated legacy folder); treat that as matching any org in the profile.
    func matches(_ accountId: String) -> Bool {
        if id == accountId { return true }
        if case let .pinned(dir, nil) = self, case let .pinned(otherDir, _) = AccountSelection(id: accountId) {
            return dir == otherDir
        }
        return false
    }

    /// Display name for the snapshot of a fetched account, honoring user renames.
    static func displayName(profileDir: String, organizationId: String, fallback: String) -> String {
        let id = AccountSelection.pinned(profileDir: profileDir, organizationId: organizationId).id
        return AppSettings.accountNames[id] ?? fallback
    }
}

struct Account: Identifiable, Equatable, Sendable {
    let profile: DesktopSession.Profile
    let organization: DesktopSession.Organization

    var id: String { AccountSelection.pinned(profileDir: profile.dir, organizationId: organization.id).id }
    var planLabel: String? { DesktopSession.planLabel(forBillingType: organization.billingType) }

    func title(disambiguate: Bool, customName: String? = nil) -> String {
        var text = customName ?? organization.name
        if let plan = planLabel { text += " — \(plan)" }
        if disambiguate, customName == nil { text += " (\(profile.name))" }
        return text
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    /// Profiles that exist but yielded no usable session, keyed by dir, with the reason.
    @Published private(set) var profileIssues: [String: String] = [:]
    @Published private(set) var profiles: [DesktopSession.Profile] = []
    @Published private(set) var activeProfileDir: String?
    @Published private(set) var isLoading = false
    @Published private(set) var selectionId = AppSettings.selectedAccountId
    @Published private(set) var hiddenIds = Set(AppSettings.hiddenAccountIds)
    @Published private(set) var customNames = AppSettings.accountNames

    static let oauthKey = AccountSelection.oauthId

    private var lastLoadedAt: Date?
    private static let cacheLifetime: TimeInterval = 600

    func select(_ selection: AccountSelection) {
        AppSettings.selectedAccountId = selection.id
        selectionId = selection.id
    }

    func syncSelection() {
        if selectionId != AppSettings.selectedAccountId {
            selectionId = AppSettings.selectedAccountId
        }
    }

    var visibleAccounts: [Account] { accounts.filter { !hiddenIds.contains($0.id) } }
    var hiddenAccounts: [Account] { accounts.filter { hiddenIds.contains($0.id) } }

    /// Titles get the profile name appended when two accounts share an org name (unless renamed).
    func title(for account: Account) -> String {
        let clash = accounts.filter { $0.organization.name == account.organization.name }.count > 1
        return account.title(disambiguate: clash, customName: customNames[account.id])
    }

    func isHidden(_ id: String) -> Bool { hiddenIds.contains(id) }

    /// Hiding the selected account switches back to Auto; returns true when that happened.
    @discardableResult
    func setHidden(_ id: String, _ hidden: Bool) -> Bool {
        if hidden { hiddenIds.insert(id) } else { hiddenIds.remove(id) }
        AppSettings.hiddenAccountIds = hiddenIds.sorted()
        if hidden, AccountSelection(id: selectionId).matches(id) {
            select(.auto)
            return true
        }
        return false
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { customNames.removeValue(forKey: id) } else { customNames[id] = trimmed }
        AppSettings.accountNames = customNames
    }

    func customName(for id: String) -> String? { customNames[id] }

    func label(for selection: AccountSelection) -> String {
        switch selection {
        case .auto: return "Auto"
        case .oauth: return customNames[Self.oauthKey] ?? "Claude Code login (OAuth)"
        case let .pinned(dir, org):
            if let account = accounts.first(where: { $0.profile.dir == dir && (org == nil || $0.organization.id == org) }) {
                return title(for: account)
            }
            return (dir as NSString).lastPathComponent
        }
    }

    func reload(force: Bool = false) {
        guard !isLoading else { return }
        if !force, let last = lastLoadedAt, Date().timeIntervalSince(last) < Self.cacheLifetime { return }
        isLoading = true
        Task { [weak self] in
            let result = await Self.load()
            guard let self else { return }
            self.profiles = result.profiles
            self.accounts = result.accounts
            self.profileIssues = result.issues
            self.activeProfileDir = result.active
            self.lastLoadedAt = Date()
            self.isLoading = false
        }
    }

    func addManualProfile(_ dir: String) {
        var dirs = AppSettings.manualProfileDirs
        guard !dirs.contains(dir) else { return }
        dirs.append(dir)
        AppSettings.manualProfileDirs = dirs
        reload(force: true)
    }

    func removeManualProfile(_ dir: String) {
        AppSettings.manualProfileDirs = AppSettings.manualProfileDirs.filter { $0 != dir }
        if case let .pinned(pinnedDir, _) = AccountSelection.current, pinnedDir == dir {
            select(.auto)
        }
        reload(force: true)
    }

    private struct LoadResult: Sendable {
        var profiles: [DesktopSession.Profile] = []
        var accounts: [Account] = []
        var issues: [String: String] = [:]
        var active: String?
    }

    private nonisolated static func load() async -> LoadResult {
        var result = LoadResult()
        let (profiles, active) = await Task.detached(priority: .utility) {
            (DesktopSession.discoverProfiles(), DesktopSession.activeDesktopProfileDirs().first)
        }.value
        result.profiles = profiles
        result.active = active
        for profile in profiles {
            guard let session = await DesktopSession.session(forProfileDir: profile.dir) else {
                result.issues[profile.dir] = DesktopSession.hasCookies(dir: profile.dir) ? "not signed in" : "no Cookies file"
                continue
            }
            do {
                let orgs = try await DesktopSession.fetchOrganizations(session: session)
                if orgs.isEmpty { result.issues[profile.dir] = "no organizations" }
                result.accounts += orgs.map { Account(profile: profile, organization: $0) }
            } catch APIError.tokenRejected {
                result.issues[profile.dir] = "session expired"
            } catch {
                result.issues[profile.dir] = "unreachable"
            }
        }
        RequestLog.write("accounts: " + result.accounts.map { "\($0.organization.name)@\($0.profile.name)" }.joined(separator: ", "))
        return result
    }
}
