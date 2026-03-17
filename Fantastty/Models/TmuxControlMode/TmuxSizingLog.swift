import Foundation

/// Temporary diagnostic logger for tmux sizing analysis.
/// Writes to /tmp/fantastty-tmux-sizing.log — remove after investigation.
enum TmuxSizingLog {
    private static let logURL = URL(fileURLWithPath: "/tmp/fantastty-tmux-sizing.log")
    private static let queue = DispatchQueue(label: "tmux-sizing-log")

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
    }
}
