import Foundation

enum OAuthRefresher {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let legacyTokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    struct Result {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date
    }

    static func refresh(refreshToken: String) async throws -> Result {
        try await perform(url: tokenURL, refreshToken: refreshToken)
    }

    private static func perform(url: URL, refreshToken: String) async throws -> Result {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UsageAPI.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("invalid response")
        }
        let code = http.statusCode
        RequestLog.write("oauth refresh \(url.path) -> \(code)")
        if (code == 404 || code == 405) && url == tokenURL {
            return try await perform(url: legacyTokenURL, refreshToken: refreshToken)
        }
        switch code {
        case 200..<300:
            break
        case 401, 403:
            throw APIError.tokenRejected
        case 429:
            throw APIError.rateLimited
        case 500..<600:
            throw APIError.server(code)
        default:
            throw APIError.http(code)
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty
        else {
            throw APIError.network("invalid refresh response")
        }
        let rotatedRefresh = json["refresh_token"] as? String
        var expiresAt = Date().addingTimeInterval(8 * 3600)
        if let expiresIn = json["expires_in"] as? NSNumber {
            expiresAt = Date().addingTimeInterval(expiresIn.doubleValue)
        }
        return Result(
            accessToken: accessToken,
            refreshToken: rotatedRefresh?.isEmpty == false ? rotatedRefresh : nil,
            expiresAt: expiresAt
        )
    }
}