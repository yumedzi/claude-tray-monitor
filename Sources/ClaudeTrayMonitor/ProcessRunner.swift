import Foundation

enum ProcessRunner {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 6) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let handle = pipe.fileHandleForReading
        var output = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false

        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                break
            }
            if let chunk = try? handle.availableData, !chunk.isEmpty {
                output.append(chunk)
            } else {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if !timedOut {
            if let rest = try? handle.readDataToEndOfFile() {
                output.append(rest)
            }
        }
        guard !timedOut else { return nil }
        return String(data: output, encoding: .utf8)
    }
}