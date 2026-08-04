import Foundation

enum RequestLog {
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    static func write(_ line: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeTrayMonitor", isDirectory: true)
        let file = dir.appendingPathComponent("requests.log")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entry = "[\(formatter.string(from: Date()))] \(line)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            try? handle.seekToEnd()
            handle.write(entry.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? entry.data(using: .utf8)?.write(to: file)
        }
    }
}