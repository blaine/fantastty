import Foundation

/// FIFO queue that matches tmux commands sent via `send()` to their
/// `%begin/%end` response blocks.
struct CommandQueue {
    struct Entry {
        let continuation: CheckedContinuation<String, any Error>?
        var responseText: String = ""
    }

    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Enqueue a continuation (or nil for fire-and-forget).
    mutating func enqueue(_ continuation: CheckedContinuation<String, any Error>?) {
        entries.append(Entry(continuation: continuation))
    }

    /// Append text to the current (first) entry's response buffer.
    mutating func appendToCurrentResponse(_ text: String) {
        guard !entries.isEmpty else { return }
        entries[0].responseText += text
    }

    /// Dequeue first entry, resume its continuation with accumulated response text.
    @discardableResult
    mutating func dequeue() -> CheckedContinuation<String, any Error>? {
        guard !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        entry.continuation?.resume(returning: entry.responseText)
        return entry.continuation
    }

    /// Dequeue first entry, resume its continuation with an error.
    mutating func dequeueWithError(_ error: any Error) {
        guard !entries.isEmpty else { return }
        let entry = entries.removeFirst()
        entry.continuation?.resume(throwing: error)
    }

    /// Raw dequeue without resuming -- for testing.
    mutating func dequeueRaw() -> (continuation: CheckedContinuation<String, any Error>?, text: String)? {
        guard !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        return (entry.continuation, entry.responseText)
    }
}
