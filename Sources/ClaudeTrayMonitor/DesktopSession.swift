import Foundation
import CommonCrypto

enum DesktopSession {
    struct Session: Sendable {
        let sessionKey: String
        let organizationId: String?
        let profileDir: String
    }

    struct Profile: Sendable, Equatable {
        let dir: String
        let isManual: Bool

        var name: String { (dir as NSString).lastPathComponent }
    }

    struct Organization: Sendable, Equatable {
        let id: String
        let name: String
        let billingType: String?
    }

    struct UsageResult: @unchecked Sendable {
        let json: [String: Any]
        let organization: Organization
    }

    static func fetchUsage(session: Session, organizationId: String? = nil) async throws -> UsageResult {
        let organizations = try await fetchOrganizations(session: session)
        let wanted = organizationId.flatMap { $0.isEmpty ? nil : $0 } ?? session.organizationId
        guard let org = organizations.first(where: { $0.id == wanted }) ?? (organizationId?.isEmpty == false ? nil : organizations.first) else {
            throw APIError.network(organizationId == nil ? "no organization found" : "organization not available for this login")
        }
        let json = try await UsageAPI.getWebJSON("/api/organizations/\(org.id)/usage", sessionKey: session.sessionKey)
        guard let dict = json as? [String: Any] else {
            throw APIError.network("invalid usage response")
        }
        return UsageResult(json: dict, organization: org)
    }

    static func planLabel(forBillingType billingType: String?) -> String? {
        guard let billingType else { return nil }
        switch billingType {
        case "stripe_subscription": return "Pro"
        case "stripe_subscription_contracted": return "Enterprise"
        default: return nil
        }
    }

    static func fetchOrganizations(session: Session) async throws -> [Organization] {
        let json = try await UsageAPI.getWebJSON("/api/organizations", sessionKey: session.sessionKey)
        let organizations = (json as? [[String: Any]]) ?? []
        RequestLog.write("orgs: " + organizations.map { "\($0["uuid"] ?? "?"):\($0["name"] ?? "?") billing=\($0["billing_type"] ?? "?") tier=\($0["rate_limit_tier"] ?? "?") caps=\(($0["capabilities"] as? [String])?.joined(separator: ",") ?? "?")" }.joined(separator: " | "))
        // API-only orgs (Console "Individual Org") have no chat usage; keep chat-capable ones when known.
        let chat = organizations.filter { ($0["capabilities"] as? [String])?.contains("chat") ?? true }
        return (chat.isEmpty ? organizations : chat).compactMap { org in
            guard let id = org["uuid"] as? String else { return nil }
            return Organization(id: id, name: (org["name"] as? String) ?? id, billingType: org["billing_type"] as? String)
        }
    }

    /// Auto mode: the running Claude Desktop's profile first, then the default profile order.
    static func activeSession() async -> Session? {
        await Task.detached(priority: .userInitiated) { computeActiveSession() }.value
    }

    static func session(forProfileDir dir: String) async -> Session? {
        await Task.detached(priority: .userInitiated) { () -> Session? in
            guard let key = cachedKey() else {
                RequestLog.write("desktop session: no safe storage key")
                return nil
            }
            for db in cookieFiles(in: URL(fileURLWithPath: dir, isDirectory: true)) {
                if let session = readCookies(db: db, key: key) { return session }
            }
            return nil
        }.value
    }

    /// All known Desktop profiles: manual folders first, then auto-discovered ones.
    static func discoverProfiles() -> [Profile] {
        var out: [Profile] = []
        for raw in AppSettings.manualProfileDirs {
            let dir = (raw as NSString).expandingTildeInPath
            if !out.contains(where: { $0.dir == dir }) {
                out.append(Profile(dir: dir, isManual: true))
            }
        }
        for dir in ProfileLocator.candidateDirs() where !cookieFiles(in: dir).isEmpty {
            if !out.contains(where: { $0.dir == dir.path }) {
                out.append(Profile(dir: dir.path, isManual: false))
            }
        }
        return out
    }

    static func hasCookies(dir: String) -> Bool {
        !cookieFiles(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)).isEmpty
    }

    static func runningPlanLabel() -> String? {
        var dirs = Set<String>()
        if let resolved = resolvedDirectory()?.path { dirs.insert(resolved) }
        guard let pids = ProcessRunner.run("/usr/bin/pgrep", ["-fi", "claude.app/Contents/MacOS/claude"], timeout: 5)?
            .split(separator: "\n").prefix(6).map(String.init) else { return nil }
        var firstPlan: String?
        for pid in pids {
            guard let env = ProcessRunner.run("/bin/ps", ["eww", "-p", pid], timeout: 5) else { continue }
            guard let plan = planLabel(fromEnv: env) else { continue }
            if firstPlan == nil { firstPlan = plan }
            if !dirs.isEmpty, dirs.contains(where: { env.contains("--user-data-dir=\($0)") }) {
                return plan
            }
        }
        return firstPlan
    }

    private static func planLabel(fromEnv env: String) -> String? {
        for token in env.split(separator: " ") {
            let part = String(token)
            if part.hasPrefix("CLAUDE_CODE_SUBSCRIPTION_TYPE=") {
                let value = String(part.dropFirst("CLAUDE_CODE_SUBSCRIPTION_TYPE=".count))
                return UsageParser.planLabel(for: value)
            }
        }
        return nil
    }

    private static func computeActiveSession() -> Session? {
        guard let key = cachedKey() else {
            RequestLog.write("desktop session: no safe storage key")
            return nil
        }
        for db in cookieDatabases() {
            if let session = readCookies(db: db, key: key) {
                return session
            }
        }
        return nil
    }

    private static func cookieDatabases() -> [String] {
        var dirs: [URL] = []
        for active in activeDesktopProfileDirs() where !dirs.contains(where: { $0.path == active }) {
            dirs.append(URL(fileURLWithPath: active, isDirectory: true))
            RequestLog.write("desktop session: active profile \(active)")
        }
        for dir in ProfileLocator.candidateDirs() where !dirs.contains(where: { $0.path == dir.path }) {
            dirs.append(dir)
        }
        var dbs: [String] = []
        for dir in dirs {
            for path in cookieFiles(in: dir) where !dbs.contains(path) {
                dbs.append(path)
            }
        }
        return dbs
    }

    private static func cookieFiles(in dir: URL) -> [String] {
        [
            dir.appendingPathComponent("Cookies"),
            dir.appendingPathComponent("Default").appendingPathComponent("Cookies"),
        ]
        .map(\.path)
        .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Profile dirs of running Claude Desktop main processes. The `--user-data-dir` value
    /// may contain spaces ("Application Support"), so it is read up to the next ` --` flag.
    static func activeDesktopProfileDirs() -> [String] {
        guard !Thread.isMainThread else { return [] }
        guard let pids = ProcessRunner.run("/usr/bin/pgrep", ["-x", ProfileLocator.desktopProcessName], timeout: 5)?
            .split(separator: "\n").prefix(8).map(String.init) else { return [] }
        var out: [String] = []
        for pid in pids {
            guard let command = ProcessRunner.run("/bin/ps", ["-o", "command=", "-p", pid], timeout: 5)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { continue }
            let dir = userDataDir(fromCommand: command) ?? ProfileLocator.defaultProfileDir.path
            let expanded = (dir as NSString).expandingTildeInPath
            if !cookieFiles(in: URL(fileURLWithPath: expanded, isDirectory: true)).isEmpty, !out.contains(expanded) {
                out.append(expanded)
            }
        }
        return out
    }

    static func userDataDir(fromCommand command: String) -> String? {
        guard let range = command.range(of: "--user-data-dir=") else { return nil }
        var value = command[range.upperBound...]
        if let next = value.range(of: " --") {
            value = value[..<next.lowerBound]
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func resolvedDirectory() -> URL? {
        cookieDatabases().first.map { db in
            var dir = URL(fileURLWithPath: (db as NSString).deletingLastPathComponent)
            if dir.lastPathComponent == "Default" { dir.deleteLastPathComponent() }
            return dir
        }
    }

    private static func readCookies(db: String, key: Data) -> Session? {
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        let rows = runSQLite(db: db, sql: """
            SELECT name, COALESCE(NULLIF(value, ''), hex(encrypted_value))
            FROM cookies
            WHERE name IN ('sessionKey', 'lastActiveOrg')
            LIMIT 8;
            """)
        var sessionKey: String?
        var organizationId: String?
        for line in rows {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let raw = parts[1].trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            let value: String?
            if raw.hasPrefix("sk-ant-") {
                value = raw
            } else {
                value = decryptCookieHex(raw, key: key)
            }
            guard let value else { continue }
            if name == "sessionKey" {
                sessionKey = value
            } else if name == "lastActiveOrg", !value.isEmpty {
                organizationId = value
            }
        }
        guard let sessionKey = sessionKey else { return nil }
        var profileDir = URL(fileURLWithPath: (db as NSString).deletingLastPathComponent)
        if profileDir.lastPathComponent == "Default" { profileDir.deleteLastPathComponent() }
        return Session(sessionKey: sessionKey, organizationId: organizationId, profileDir: profileDir.path)
    }

    private static func decryptCookieHex(_ hex: String, key: Data) -> String? {
        guard let data = Data(hexString: hex), data.count >= 4 else { return nil }
        let prefix = data.subdata(in: 0..<3)
        guard prefix == Data("v10".utf8) || prefix == Data("v11".utf8) else { return nil }
        let ciphertext = data.subdata(in: 3..<data.count)
        guard let plain = aesCBCDecrypt(ciphertext, key: key, iv: Data(repeating: 0x20, count: kCCBlockSizeAES128)) else { return nil }
        guard plain.count > 32 else { return nil }
        let value = plain.subdata(in: 32..<plain.count)
        guard let text = String(data: value, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let keyCache = KeyCache()

    private static func cachedKey() -> Data? {
        if let key = keyCache.get() { return key }
        let key = deriveKey()
        if let key { keyCache.set(key) }
        return key
    }

    private static func deriveKey() -> Data? {
        let output = runSecurity(args: ["find-generic-password", "-w", "-s", "Claude Safe Storage", "-a", "Claude Key"])
        guard let output else { return nil }
        let password = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { return nil }
        let salt = Data("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: 16)
        let status = password.withCString { pass -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pass, strlen(pass),
                (salt as NSData).bytes, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                1003,
                &key, key.count
            )
        }
        guard status == 0 else { return nil }
        return Data(key)
    }

    private static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = data.withUnsafeBytes { cipherBytes -> CCCryptorStatus in
            key.withUnsafeBytes { keyBytes -> CCCryptorStatus in
                iv.withUnsafeBytes { ivBytes -> CCCryptorStatus in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        ivBytes.baseAddress,
                        cipherBytes.baseAddress, data.count,
                        &out, out.count, &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(outLen))
    }

    private static func runSecurity(args: [String]) -> String? {
        ProcessRunner.run("/usr/bin/security", args, timeout: 8)
    }

    private static func runSQLite(db: String, sql: String) -> [String] {
        guard let output = ProcessRunner.run("/usr/bin/sqlite3", ["-readonly", "-separator", "\t", db, sql], timeout: 8) else { return [] }
        return output.split(separator: "\n").map(String.init)
    }
}

/// Where Claude Desktop keeps its Chromium profiles. Only the macOS layout is wired up today;
/// a Windows port would use %APPDATA%\\Claude* and DPAPI-protected cookie keys instead.
enum ProfileLocator {
    #if os(macOS)
    static let desktopProcessName = "Claude"
    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }
    #else
    static let desktopProcessName = "Claude.exe"
    static var supportDir: URL {
        let appData = ProcessInfo.processInfo.environment["APPDATA"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: appData, isDirectory: true)
    }
    #endif

    static var defaultProfileDir: URL {
        supportDir.appendingPathComponent("Claude", isDirectory: true)
    }

    /// `Claude` first (modern Desktop), then any other `Claude-*` profile, alphabetically.
    static func candidateDirs() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: supportDir.path)) ?? []
        let extra = names.filter { $0.hasPrefix("Claude-") }.sorted()
        return (["Claude"] + extra).map { supportDir.appendingPathComponent($0, isDirectory: true) }
    }
}

private final class KeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    func get() -> Data? { lock.withLock { key } }
    func set(_ value: Data) { lock.withLock { key = value } }
}

private extension Data {
    init?(hexString: String) {
        let clean = hexString.filter { $0.isHexDigit }
        guard !clean.isEmpty, clean.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}