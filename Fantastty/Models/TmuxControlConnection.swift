import Foundation
import os

/// Information about a tmux pane within a window.
struct TmuxPane {
    let paneId: Int
    let windowId: Int
}

/// Information about a tmux window discovered via control mode.
struct TmuxWindow {
    let windowId: Int
    var panes: [TmuxPane]
}

/// Delegate protocol for tmux control mode events.
protocol TmuxControlConnectionDelegate: AnyObject {
    /// Called when the window/pane list changes (windows added, removed, or layout changed).
    func controlConnection(_ connection: TmuxControlConnection, windowsChanged windows: [TmuxWindow])

    /// Called when a pane produces output.
    func controlConnection(_ connection: TmuxControlConnection, paneOutput paneId: Int, data: Data)

    /// Called when a window is closed.
    func controlConnection(_ connection: TmuxControlConnection, windowClosed windowId: Int)

    /// Called when the control connection exits.
    func controlConnectionDidExit(_ connection: TmuxControlConnection)
}

/// Manages a single `tmux -CC` control mode connection for a workspace.
///
/// The control mode protocol is text-based: tmux sends notifications prefixed with `%`
/// and responses to commands are wrapped in `%begin`/`%end` blocks.
class TmuxControlConnection {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "tmux-control"
    )

    /// File-based debug log (os.Logger debug messages aren't persisted)
    private static func debugLog(_ message: String) {
        let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".fantastty_debug.log")
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] TMUX: \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    let tmuxPath: String
    let sessionName: String
    weak var delegate: TmuxControlConnectionDelegate?

    private var process: Process?
    private var stdinHandle: FileHandle?
    /// PTY master file descriptor used for stdin/stdout (tmux requires a terminal)
    private var ptyMaster: Int32 = -1

    /// Background queue for reading stdout
    private let readQueue = DispatchQueue(label: "com.fantastty.tmux-control.read", qos: .userInitiated)

    /// FIFO queue of pending command callbacks.
    /// Each command we send pushes a callback (or nil for fire-and-forget).
    /// Each %begin/%end block pops the front entry.
    private var callbackQueue: [((Result<[String], TmuxControlError>) -> Void)?] = []

    /// State for accumulating %begin/%end blocks
    private var currentBlockNumber: Int?
    private var currentBlockLines: [String] = []
    private var currentBlockIsError: Bool = false

    /// Whether the initial handshake is complete
    private var isReady = false

    /// Known windows and panes
    private(set) var windows: [TmuxWindow] = []

    enum TmuxControlError: Error {
        case processNotRunning
        case commandFailed(String)
        case parseError(String)
    }

    init(tmuxPath: String, sessionName: String, delegate: TmuxControlConnectionDelegate? = nil) {
        self.tmuxPath = tmuxPath
        self.sessionName = sessionName
        self.delegate = delegate
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    /// Start the control mode connection.
    func start() {
        // tmux requires a terminal on stdin (tcgetattr), even in -CC mode.
        // Create a PTY pair: slave end for tmux's stdin, master end for us to write commands.
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            Self.logger.error("Failed to open PTY for tmux control connection")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        proc.arguments = ["-CC", "new-session", "-A", "-s", sessionName]

        // stdin = PTY slave (so tmux sees a terminal)
        // stdout/stderr = /dev/null (all control mode output comes through the PTY)
        proc.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            DispatchQueue.main.async {
                Self.logger.info("Control connection exited for session \(self.sessionName) status=\(proc.terminationStatus)")
                self.delegate?.controlConnectionDidExit(self)
            }
        }

        do {
            try proc.run()
            // Close slave in parent — tmux inherited it
            close(slave)
            self.process = proc
            self.ptyMaster = master
            self.stdinHandle = FileHandle(fileDescriptor: master, closeOnDealloc: false)
            Self.logger.info("Started control connection for session \(self.sessionName) (pid=\(proc.processIdentifier))")
            startReading()
        } catch {
            close(master)
            close(slave)
            Self.logger.error("Failed to start tmux control connection: \(error)")
        }
    }

    /// Stop the control mode connection.
    func stop() {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
        stdinHandle = nil
        if ptyMaster >= 0 {
            close(ptyMaster)
            ptyMaster = -1
        }
        callbackQueue.removeAll()
    }

    /// Whether the connection is alive.
    var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - Command Sending

    /// Write a command to tmux stdin without tracking it in the callback queue.
    private func sendRaw(_ command: String) {
        guard let handle = stdinHandle else {
            Self.logger.warning("Cannot send command: stdin handle not available")
            return
        }
        let line = command.hasSuffix("\n") ? command : command + "\n"
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }

    /// Send a fire-and-forget command to tmux.
    /// Registers a nil entry in the callback queue so FIFO ordering stays correct.
    func send(_ command: String) {
        Self.debugLog("send(fire-and-forget): '\(command)' queue_pos=\(callbackQueue.count)")
        callbackQueue.append(nil)
        sendRaw(command)
    }

    /// Send a command and receive the response asynchronously.
    func send(_ command: String, completion: @escaping (Result<[String], TmuxControlError>) -> Void) {
        Self.debugLog("send(callback): '\(command)' queue_pos=\(callbackQueue.count)")
        callbackQueue.append(completion)
        sendRaw(command)
    }

    // MARK: - Reading

    private func startReading() {
        guard ptyMaster >= 0 else { return }
        let fd = ptyMaster

        readQueue.async { [weak self] in
            var buffer = Data()
            var buf = [UInt8](repeating: 0, count: 8192)
            var strippedDCS = false

            while let self = self, self.isRunning {
                let n = read(fd, &buf, buf.count)
                if n <= 0 {
                    // EOF or error
                    break
                }

                buffer.append(contentsOf: buf[0..<n])

                // tmux -CC wraps output in a DCS sequence: \x1bP1000p
                // Strip it once at the beginning of the stream.
                if !strippedDCS {
                    let preview = String(data: buffer.prefix(40), encoding: .utf8) ?? buffer.prefix(40).map { String(format: "%02x", $0) }.joined(separator: " ")
                    Self.debugLog("DCS check: buffer[\(buffer.count)]= \(preview)")
                    if let dcsEnd = buffer.range(of: Data("1000p".utf8)) {
                        buffer.removeSubrange(buffer.startIndex...dcsEnd.upperBound - 1)
                        strippedDCS = true
                        Self.debugLog("DCS stripped, remaining=\(buffer.count) bytes")
                    } else if buffer.count > 20 {
                        // No DCS prefix found — proceed without stripping
                        strippedDCS = true
                        Self.debugLog("DCS not found, proceeding without strip")
                    } else {
                        // Wait for more data
                        continue
                    }
                }

                // Process complete lines (PTY uses \r\n)
                while let newlineRange = buffer.range(of: Data([0x0A])) {
                    var lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                    buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                    // Strip trailing \r from \r\n
                    if lineData.last == 0x0D {
                        lineData = lineData.dropLast()
                    }

                    if let line = String(data: lineData, encoding: .utf8) {
                        self.processLine(line)
                    }
                }
            }
        }
    }

    // MARK: - Protocol Parsing

    private func processLine(_ line: String) {
        // Log all non-output lines for debugging
        if !line.hasPrefix("%output") {
            Self.debugLog("processLine: \(line)")
        }

        // Inside a %begin/%end block, accumulate lines
        if currentBlockNumber != nil {
            if line.hasPrefix("%end") || line.hasPrefix("%error") {
                let isError = line.hasPrefix("%error")
                finishBlock(isError: isError)
                return
            }
            currentBlockLines.append(line)
            return
        }

        // Parse notification lines
        if line.hasPrefix("%begin") {
            handleBegin(line)
        } else if line.hasPrefix("%output") {
            handleOutput(line)
        } else if line.hasPrefix("%window-add") {
            handleWindowAdd(line)
        } else if line.hasPrefix("%window-close") {
            handleWindowClose(line)
        } else if line.hasPrefix("%layout-change") {
            handleLayoutChange(line)
        } else if line.hasPrefix("%session-changed") {
            handleSessionChanged(line)
        } else if line.hasPrefix("%exit") {
            handleExit(line)
        }
        // Ignore unrecognized lines (including initial greeting)
    }

    // MARK: - Block Handling

    /// `%begin <timestamp> <command_number> <flags>`
    private func handleBegin(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 3)
        guard parts.count >= 3, let number = Int(parts[2]) else {
            Self.debugLog("handleBegin: unparseable, parts=\(parts), setting blockNumber=-1")
            currentBlockNumber = -1
            currentBlockLines = []
            currentBlockIsError = false
            return
        }
        Self.debugLog("handleBegin: blockNumber=\(number)")
        currentBlockNumber = number
        currentBlockLines = []
        currentBlockIsError = false
    }

    /// Finish the current block and deliver to any pending callback.
    private func finishBlock(isError: Bool) {
        guard let number = currentBlockNumber else { return }
        let lines = currentBlockLines

        currentBlockNumber = nil
        currentBlockLines = []
        currentBlockIsError = false

        Self.debugLog("finishBlock: tmux_cmd=\(number) isError=\(isError) isReady=\(isReady) lines=\(lines.count) queue=\(callbackQueue.count)")

        // Initial handshake block — not a response to any command we sent
        if !isReady {
            isReady = true
            Self.debugLog("finishBlock: HANDSHAKE COMPLETE")
            refreshWindows()
            return
        }

        // Pop the next callback from the FIFO queue
        guard !callbackQueue.isEmpty else {
            Self.debugLog("finishBlock: queue empty, ignoring block")
            return
        }
        let callback = callbackQueue.removeFirst()
        if let callback = callback {
            Self.debugLog("finishBlock: delivering \(lines.count) lines to callback")
            if isError {
                callback(.failure(.commandFailed(lines.joined(separator: "\n"))))
            } else {
                callback(.success(lines))
            }
        } else {
            Self.debugLog("finishBlock: fire-and-forget (nil callback), skipping")
        }
    }

    // MARK: - Notification Handlers

    /// `%output %<pane_id> <data>`
    private func handleOutput(_ line: String) {
        // Format: %output %<pane_id> <octal-escaped data>
        guard line.count > 8 else { return }  // "%output " is 8 chars

        let afterPrefix = line[line.index(line.startIndex, offsetBy: 8)...]

        // Find the pane ID: starts with %, ends at the next space
        guard afterPrefix.hasPrefix("%"),
              let spaceIdx = afterPrefix.dropFirst().firstIndex(of: " "),
              let paneId = Int(afterPrefix[afterPrefix.index(after: afterPrefix.startIndex)..<spaceIdx]) else {
            return
        }

        let encodedData = afterPrefix[afterPrefix.index(after: spaceIdx)...]
        let rawDecoded = decodeOctalEscapes(String(encodedData))
        let decoded = Self.filterScreenSequences(rawDecoded)

        // Log decoded output for debugging (first 80 bytes as hex + printable)
        let preview = decoded.prefix(80).map { byte -> String in
            if byte >= 0x20 && byte < 0x7F {
                return String(Character(UnicodeScalar(byte)))
            } else {
                return String(format: "\\x%02x", byte)
            }
        }.joined()
        Self.debugLog("output %\(paneId) [\(decoded.count)b]: \(preview)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.controlConnection(self, paneOutput: paneId, data: decoded)
        }
    }

    /// `%window-add @<id>`
    private func handleWindowAdd(_ line: String) {
        Self.logger.info("Window added: \(line)")
        refreshWindows()
    }

    /// `%window-close @<id>`
    private func handleWindowClose(_ line: String) {
        // Extract window ID from `%window-close @<id>`
        let parts = line.split(separator: " ")
        if parts.count >= 2, parts[1].hasPrefix("@"),
           let windowId = Int(parts[1].dropFirst()) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.windows.removeAll { $0.windowId == windowId }
                self.delegate?.controlConnection(self, windowClosed: windowId)
            }
        }
    }

    /// `%layout-change @<id> <layout>`
    private func handleLayoutChange(_ line: String) {
        Self.logger.info("Layout changed: \(line)")
        refreshWindows()
    }

    /// `%session-changed $<id> <name>`
    private func handleSessionChanged(_ line: String) {
        Self.logger.info("Session changed: \(line)")
        if isReady {
            refreshWindows()
        }
    }

    /// `%exit [reason]`
    private func handleExit(_ line: String) {
        Self.logger.info("Control connection exit notification: \(line)")
        // The termination handler will fire the delegate callback
    }

    // MARK: - Window Discovery

    /// Query tmux for the current list of windows and panes.
    func refreshWindows() {
        send("list-panes -s -F '#{window_id} #{pane_id}'") { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let lines):
                self.parseWindowPaneList(lines)
            case .failure(let error):
                Self.logger.error("Failed to list panes: \(error)")
            }
        }
    }

    /// Parse the output of `list-panes -s` and update the window/pane model.
    private func parseWindowPaneList(_ lines: [String]) {
        var windowMap: [Int: TmuxWindow] = [:]

        for line in lines {
            // Format: @<window_id> %<pane_id>
            let parts = line.split(separator: " ")
            guard parts.count >= 2,
                  parts[0].hasPrefix("@"), parts[1].hasPrefix("%"),
                  let windowId = Int(parts[0].dropFirst()),
                  let paneId = Int(parts[1].dropFirst()) else {
                continue
            }

            if windowMap[windowId] == nil {
                windowMap[windowId] = TmuxWindow(windowId: windowId, panes: [])
            }
            windowMap[windowId]?.panes.append(TmuxPane(paneId: paneId, windowId: windowId))
        }

        let newWindows = windowMap.values.sorted { $0.windowId < $1.windowId }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.windows = newWindows
            self.delegate?.controlConnection(self, windowsChanged: newWindows)
        }
    }

    /// Capture the visible content of a pane (for initial display after connect).
    func capturePane(paneId: Int, completion: @escaping (Data?) -> Void) {
        send("capture-pane -t %\(paneId) -p -e") { result in
            switch result {
            case .success(let lines):
                let text = lines.joined(separator: "\n") + "\n"
                completion(text.data(using: .utf8))
            case .failure:
                completion(nil)
            }
        }
    }

    // MARK: - Output Filtering

    /// Strip screen/tmux-specific escape sequences that Ghostty doesn't understand.
    ///
    /// The tmux pane uses TERM=screen-256color, which sets window titles with
    /// `ESC k <title> ST` (where ST = `ESC \`). Ghostty doesn't recognize `ESC k`
    /// and renders the title text as visible output. Strip these sequences.
    static func filterScreenSequences(_ data: Data) -> Data {
        let esc: UInt8 = 0x1B
        let k: UInt8 = 0x6B       // 'k'
        let backslash: UInt8 = 0x5C  // '\'

        var result = Data()
        result.reserveCapacity(data.count)

        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == esc, i + 1 < data.endIndex, data[i + 1] == k {
                // Found ESC k — skip until ESC \ (ST)
                var j = i + 2
                var foundST = false
                while j < data.endIndex {
                    if data[j] == esc, j + 1 < data.endIndex, data[j + 1] == backslash {
                        j += 2  // Skip the ST
                        foundST = true
                        break
                    }
                    j += 1
                }
                if foundST {
                    i = j
                } else {
                    // Incomplete sequence — keep data from ESC k onward
                    result.append(contentsOf: data[i..<data.endIndex])
                    i = data.endIndex
                }
            } else {
                result.append(data[i])
                i += 1
            }
        }

        return result
    }

    // MARK: - Octal Escape Decoding

    /// Decode tmux control mode octal escapes in `%output` data.
    ///
    /// Characters < 32 and backslash are encoded as `\NNN` (3 octal digits).
    /// e.g. `\015` = CR, `\012` = LF, `\134` = `\`
    static func decodeOctalEscapes(_ string: String) -> Data {
        var result = Data()
        result.reserveCapacity(string.utf8.count)

        var iter = string.utf8.makeIterator()
        while let byte = iter.next() {
            if byte == UInt8(ascii: "\\") {
                // Try to read 3 octal digits
                var octalDigits: [UInt8] = []
                for _ in 0..<3 {
                    guard let next = iter.next(), next >= UInt8(ascii: "0"), next <= UInt8(ascii: "7") else {
                        // Not a valid octal escape; emit backslash and whatever we got
                        result.append(byte)
                        for d in octalDigits { result.append(d) }
                        break
                    }
                    octalDigits.append(next)
                }
                if octalDigits.count == 3 {
                    let value = (octalDigits[0] - UInt8(ascii: "0")) * 64
                             + (octalDigits[1] - UInt8(ascii: "0")) * 8
                             + (octalDigits[2] - UInt8(ascii: "0"))
                    result.append(value)
                }
            } else {
                result.append(byte)
            }
        }

        return result
    }

    /// Convenience wrapper returning Data for the delegate interface.
    private func decodeOctalEscapes(_ string: String) -> Data {
        Self.decodeOctalEscapes(string)
    }
}
