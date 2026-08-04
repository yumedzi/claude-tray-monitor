import Foundation

enum APIError: Error, Sendable {
    case tokenRejected
    case rateLimited
    case http(Int)
    case server(Int)
    case network(String)
}

enum UsageAPI {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let userAgent = "claude-tray-monitor/0.1.0"

    static func getJSON(_ url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            request.httpMethod = "GET"
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw APIError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.network("invalid response")
        }
        let code = http.statusCode
        RequestLog.write("\(url.path) -> \(code)")
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

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.network("invalid JSON")
        }
        return json
    }
}