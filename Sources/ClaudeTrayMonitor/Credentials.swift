import Foundation

struct TokenCandidate: Sendable, Equatable {
    let token: String
    let source: String
    let subscriptionType: String?
    let expiresAt: Date?
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

    static func candidates() -> [TokenCandidate] {
        var seen = Set<String>()
        var out: [TokenCandidate] = []

        if let token = readFileToken() {
            seen.insert(token.token)
            out.append(token)
        }
        if let token = readKeychainToken(), !seen.contains(token.token) {
            out.append(token)
        }
        return out
    }

    static func activeToken() -> TokenCandidate? {
        candidates().first
    }

    private static func readFileToken() -> TokenCandidate? {
        let file = claudeConfigDir.appendingPathComponent(".credentials.json")
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return candidate(from: oauthBlob(json), source: "file")
    }

    private static func readKeychainToken() -> TokenCandidate? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return nil }
            return candidate(from: oauthBlob(json), source: "keychain")
        } catch {
            return nil
        }
    }

    private static func oauthBlob(_ json: [String: Any]) -> [String: Any] {
        (json["claudeAiOauth"] as? [String: Any]) ?? json
    }

    private static func candidate(from oauth: [String: Any], source: String) -> TokenCandidate? {
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        var expiresAt: Date?
        if let ms = oauth["expiresAt"] as? NSNumber {
            expiresAt = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        }
        let subscriptionType = oauth["subscriptionType"] as? String
        return TokenCandidate(token: token, source: source, subscriptionType: subscriptionType, expiresAt: expiresAt)
    }
}