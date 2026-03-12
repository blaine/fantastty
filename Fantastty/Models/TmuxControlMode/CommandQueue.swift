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

    /// Peek current response buffer without dequeuing.
    mutating func currentResponseText() -> String? {
        entries.first?.responseText
    }

    /// Replace current response buffer with a fully assembled block response.
    mutating func setCurrentResponse(_ text: String) {
        guard !entries.isEmpty else { return }
        entries[0].responseText = text
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

/// Tracks an active tmux command block (`%begin` ... `%end`/`%error`) and
/// accumulates its response payload deterministically.
struct TmuxControlBlockTracker {
    enum Error: Swift.Error, Equatable {
        case nestedBegin(activeID: Int, newID: Int)
        case unexpectedEnd(id: Int, flags: Int)
        case unexpectedError(id: Int, flags: Int)
        case mismatchedEnd(expectedID: Int, actualID: Int)
        case mismatchedError(expectedID: Int, actualID: Int)
    }

    private struct ActiveBlock {
        let id: Int
        let flags: Int
        var response: String = ""
    }

    private var activeBlock: ActiveBlock?

    var hasActiveBlock: Bool {
        activeBlock != nil
    }

    mutating func begin(id: Int, flags: Int) throws {
        if let activeBlock {
            throw Error.nestedBegin(activeID: activeBlock.id, newID: id)
        }
        activeBlock = ActiveBlock(id: id, flags: flags)
    }

    mutating func append(_ line: String) {
        guard var activeBlock else { return }
        activeBlock.response += line
        self.activeBlock = activeBlock
    }

    mutating func end(id: Int, flags: Int) throws -> String {
        guard let activeBlock else {
            throw Error.unexpectedEnd(id: id, flags: flags)
        }
        guard activeBlock.id == id else {
            throw Error.mismatchedEnd(expectedID: activeBlock.id, actualID: id)
        }
        self.activeBlock = nil
        return activeBlock.response
    }

    mutating func error(id: Int, flags: Int) throws -> String {
        guard let activeBlock else {
            throw Error.unexpectedError(id: id, flags: flags)
        }
        guard activeBlock.id == id else {
            throw Error.mismatchedError(expectedID: activeBlock.id, actualID: id)
        }
        self.activeBlock = nil
        return activeBlock.response
    }

    mutating func reset() {
        activeBlock = nil
    }
}

extension TmuxControlBlockTracker.Error: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .nestedBegin(let activeID, let newID):
            return "nested %begin for command \(newID) while block \(activeID) is active"
        case .unexpectedEnd(let id, _):
            return "received %end for command \(id) without active block"
        case .unexpectedError(let id, _):
            return "received %error for command \(id) without active block"
        case .mismatchedEnd(let expectedID, let actualID):
            return "received %end for command \(actualID) while command \(expectedID) is active"
        case .mismatchedError(let expectedID, let actualID):
            return "received %error for command \(actualID) while command \(expectedID) is active"
        }
    }
}
