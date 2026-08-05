import Foundation

struct TokenCandidate: Sendable, Equatable {
    let token: String
    let source: String
    let subscriptionType: String?
    let expiresAt: Date?
    let refreshToken: String?
    let service: String?
    let account: String?
    let rawJSON: Data?

    func refreshed(accessToken: String, refreshToken: String, expiresAt: Date) -> TokenCandidate {
        TokenCandidate(
            token: accessToken,
            source: source,
            subscriptionType: subscriptionType,
            expiresAt: expiresAt,
            refreshToken: refreshToken,
            service: service,
            account: account,
            rawJSON: rawJSON
        )
    }
}

enum TokenResolver {
    static let overrideEnvVars: [String] = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
    ]

    private static let baseService = "Claude Code-credentials"
    private static let swapService = "claude-swap"

    static func detectAuthOverride(env: [String: String]) -> String? {
        overrideEnvVars.first { env[$0] != nil }
    }

    static var claudeConfigDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    static func candidatesAsync() async -> [TokenCandidate] {
        await Task.detached(priority: .userInitiated) { candidates() }.value
    }

    static func candidates() -> [TokenCandidate] {
        var seen = Set<String>()
        var out: [TokenCandidate] = []

        if let token = readFileToken() {
            seen.insert(token.token)
            out.append(token)
        }
        let keychainTokens = readKeychainTokens().filter { !seen.contains($0.token) }
        seen.formUnion(keychainTokens.map(\.token))
        out.append(contentsOf: keychainTokens.sorted { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (.some(a), .some(b)): return a > b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        })
        return out
    }

    static func activeToken() -> TokenCandidate? {
        candidates().first
    }

    static func quickPlanLabel() -> String? {
        guard let raw = ProcessRunner.run("/usr/bin/security", ["find-generic-password", "-s", baseService, "-w"], timeout: 5),
              let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        else { return nil }
        let oauth = oauthBlob(json)
        guard let type = oauth["subscriptionType"] as? String else { return nil }
        return UsageParser.planLabel(for: type)
    }

    static func writeBackRotatedTokens(for candidate: TokenCandidate, accessToken: String, refreshToken: String?, expiresAt: Date) {
        guard let service = candidate.service,
              let account = candidate.account,
              let raw = candidate.rawJSON,
              var json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        else { return }
        var oauth = oauthBlob(json)
        oauth["accessToken"] = accessToken
        if let refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        json["claudeAiOauth"] = oauth
        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let jsonString = String(data: newData, encoding: .utf8)
        else { return }

        _ = ProcessRunner.run("/usr/bin/security", ["add-generic-password", "-U", "-a", account, "-s", service, "-w", jsonString], timeout: 10)
        RequestLog.write("keychain updated: \(service)")
    }

    private static func readFileToken() -> TokenCandidate? {
        let file = claudeConfigDir.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return candidate(from: oauthBlob(json), source: "file")
    }

    private static func readKeychainTokens() -> [TokenCandidate] {
        keychainEntries()
            .filter { $0.service == baseService || $0.service == swapService || $0.service.hasPrefix("\(baseService)-") }
            .compactMap { entry -> TokenCandidate? in
                guard let data = keychainData(service: entry.service, account: entry.account),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                else { return nil }
                return candidate(
                    from: oauthBlob(json),
                    source: sourceLabel(for: entry.service),
                    service: entry.service,
                    account: entry.account,
                    rawJSON: data
                )
            }
    }

    private static func keychainEntries() -> [(service: String, account: String)] {
        let text = ProcessRunner.run("/usr/bin/security", ["dump-keychain"], timeout: 15) ?? ""
        guard !text.isEmpty else { return [] }

        var entries: [(service: String, account: String)] = []
        var service = ""
        var account = ""
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("keychain:") || trimmed.hasPrefix("class:") {
                if !service.isEmpty, !account.isEmpty {
                    entries.append((service, account))
                }
                service = ""
                account = ""
            } else if trimmed.hasPrefix("\"svce\"<blob>=") {
                service = unquoteDump(trimmed)
            } else if trimmed.hasPrefix("\"acct\"<blob>=") {
                account = unquoteDump(trimmed)
            }
        }
        if !service.isEmpty, !account.isEmpty {
            entries.append((service, account))
        }
        return entries
    }

    private static func unquoteDump(_ line: String) -> String {
        guard let from = line.firstIndex(of: "=") else { return "" }
        var value = String(line[line.index(after: from)...])
        value = value.replacingOccurrences(of: "\"", with: "")
        return value
    }

    private static func keychainData(service: String, account: String) -> Data? {
        let output = ProcessRunner.run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], timeout: 5)
        guard let output else { return nil }
        return output.data(using: .utf8)
    }

    private static func sourceLabel(for service: String) -> String {
        switch service {
        case baseService: return "Claude Code credentials"
        case swapService: return "System token (swapped)"
        default:
            let tail = service.dropFirst("\(baseService)-".count)
            return "Claude Code credentials \((String(tail).isEmpty) ? "" : " (\(tail))")"
        }
    }

    private static func oauthBlob(_ json: [String: Any]) -> [String: Any] {
        (json["claudeAiOauth"] as? [String: Any]) ?? json
    }

    private static func candidate(from oauth: [String: Any], source: String, service: String? = nil, account: String? = nil, rawJSON: Data? = nil) -> TokenCandidate? {
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        var expiresAt: Date?
        if let ms = oauth["expiresAt"] as? NSNumber {
            expiresAt = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        }
        let subscriptionType = oauth["subscriptionType"] as? String
        let refreshToken = oauth["refreshToken"] as? String
        return TokenCandidate(
            token: token,
            source: source,
            subscriptionType: subscriptionType,
            expiresAt: expiresAt,
            refreshToken: refreshToken,
            service: service,
            account: account,
            rawJSON: rawJSON
        )
    }
}