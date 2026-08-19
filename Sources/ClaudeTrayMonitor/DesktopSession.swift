import Foundation
import CommonCrypto

enum DesktopSession {
    struct Session {
        let sessionKey: String
        let organizationId: String?
    }

    static func fetchUsage(session: Session) async throws -> (json: [String: Any], billingType: String?) {
        let org = try await resolveOrganization(session: session)
        guard let organizationId = org["uuid"] as? String else {
            throw APIError.network("no organization id")
        }
        let json = try await UsageAPI.getWebJSON("/api/organizations/\(organizationId)/usage", sessionKey: session.sessionKey)
        guard let dict = json as? [String: Any] else {
            throw APIError.network("invalid usage response")
        }
        return (dict, org["billing_type"] as? String)
    }

    static func planLabel(forBillingType billingType: String?) -> String? {
        guard let billingType else { return nil }
        switch billingType {
        case "stripe_subscription": return "Pro"
        case "stripe_subscription_contracted": return "Enterprise"
        default: return nil
        }
    }

    private static func resolveOrganization(session: Session) async throws -> [String: Any] {
        let json = try await UsageAPI.getWebJSON("/api/organizations", sessionKey: session.sessionKey)
        let organizations = (json as? [[String: Any]]) ?? []
        RequestLog.write("orgs: " + organizations.map { "\($0["uuid"] ?? "?"):\($0["name"] ?? "?") billing=\($0["billing_type"] ?? "?") tier=\($0["rate_limit_tier"] ?? "?")" }.joined(separator: " | "))
        let ids = organizations.compactMap { $0["uuid"] as? String }
        if let preferred = session.organizationId, ids.contains(preferred),
           let org = organizations.first(where: { $0["uuid"] as? String == preferred }) {
            return org
        }
        if let first = ids.first,
           let org = organizations.first(where: { $0["uuid"] as? String == first }) {
            return org
        }
        if let preferred = session.organizationId,
           let org = organizations.first(where: { $0["uuid"] as? String == preferred }) {
            return org
        }
        throw APIError.network("no organization found")
    }

    static func activeSession() async -> Session? {
        await Task.detached(priority: .userInitiated) { computeActiveSession() }.value
    }

    static func runningPlanLabel() -> String? {
        var dirs = Set<String>()
        if let configured = configuredDirectory()?.path { dirs.insert(configured) }
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
        guard let key = deriveKey() else {
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
        if let configured = configuredDirectory() {
            dirs.append(configured)
            RequestLog.write("desktop session: using configured dir \(configured.path)")
        }
        if let active = activeDesktopProfileDir(), !dirs.contains(where: { $0.path == active }) {
            dirs.append(URL(fileURLWithPath: active, isDirectory: true))
            RequestLog.write("desktop session: active profile \(active)")
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        for name in ["Claude", "Claude-Personal"] {
            let dir = support.appendingPathComponent(name, isDirectory: true)
            if !dirs.contains(dir) {
                dirs.append(dir)
            }
        }
        var dbs: [String] = []
        for dir in dirs {
            let candidates = [
                dir.appendingPathComponent("Cookies"),
                dir.appendingPathComponent("Default").appendingPathComponent("Cookies"),
            ]
            for db in candidates {
                let path = db.path
                if FileManager.default.fileExists(atPath: path), !dbs.contains(path) {
                    dbs.append(path)
                }
            }
        }
        return dbs
    }

    private static func activeDesktopProfileDir() -> String? {
        guard !Thread.isMainThread else { return nil }
        guard let pids = ProcessRunner.run("/usr/bin/pgrep", ["-fi", "claude.app/Contents/MacOS/claude"], timeout: 5)?
            .split(separator: "\n").prefix(8).map(String.init) else { return nil }
        for pid in pids {
            guard let env = ProcessRunner.run("/bin/ps", ["eww", "-p", pid], timeout: 5) else { continue }
            for token in env.split(separator: " ") {
                let part = String(token)
                guard part.hasPrefix("--user-data-dir=") else { continue }
                let dir = String(part.dropFirst("--user-data-dir=".count))
                let cookies = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("Cookies")
                if FileManager.default.fileExists(atPath: cookies.path) {
                    return dir
                }
            }
        }
        return nil
    }

    static func resolvedDirectory() -> URL? {
        cookieDatabases().first.map { URL(fileURLWithPath: ($0 as NSString).deletingLastPathComponent) }
    }

    private static func configuredDirectory() -> URL? {
        let raw = AppSettings.desktopDataDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
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
        return Session(sessionKey: sessionKey, organizationId: organizationId)
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