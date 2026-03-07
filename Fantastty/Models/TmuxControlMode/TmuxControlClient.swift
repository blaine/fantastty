import Foundation

// MARK: - TmuxWindow

struct TmuxWindow: Sendable {
    let windowID: Int
    var name: String
}

// MARK: - TmuxControlError

enum TmuxControlError: Error, Sendable {
    case notConnected
    case processTerminated
    case serverError(String)
}

// MARK: - TmuxControlClientDelegate

@MainActor
protocol TmuxControlClientDelegate: AnyObject {
    func controlClient(_ client: TmuxControlClient, didAddWindow window: TmuxWindow)
    func controlClient(_ client: TmuxControlClient, didCloseWindowID windowID: Int)
    func controlClient(_ client: TmuxControlClient, didRenameWindowID windowID: Int, to name: String)
    func controlClient(_ client: TmuxControlClient, didChangeLayoutForWindowID windowID: Int, layout: String)
    func controlClient(_ client: TmuxControlClient, didReceiveOutput data: Data, forPaneID paneID: Int)
    func controlClient(_ client: TmuxControlClient, didChangeState state: ConnectionState)
    func controlClientDidExit(_ client: TmuxControlClient, reason: String?)
}

// MARK: - TmuxCommandSending

/// Protocol for sending commands to a tmux session.
/// Allows testing SessionManager without a real TmuxControlClient.
protocol TmuxCommandSending: AnyObject {
    func newWindow() async throws -> String
    func killWindow(windowID: Int) async throws
    func renameWindow(windowID: Int, name: String) async throws
    func splitPane(paneID: Int, horizontal: Bool) async throws
    func killPane(paneID: Int) async throws
}

// MARK: - TmuxControlClient

actor TmuxControlClient {
    let attachmentInfo: TmuxAttachmentInfo

    nonisolated(unsafe) weak var delegate: (any TmuxControlClientDelegate)?

    private var parser = TmuxProtocolParser()
    private var commandQueue = CommandQueue()
    private(set) var windows: [Int: TmuxWindow] = [:]
    private(set) var state: ConnectionState = .disconnected(reason: nil)
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readTask: Task<Void, Never>?
    private var inBlock = false

    init(attachmentInfo: TmuxAttachmentInfo) {
        self.attachmentInfo = attachmentInfo
    }

    // MARK: - Connection Lifecycle

    func connect() async throws {
        let command = attachmentInfo.controlCommand()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]

        let stdoutPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardInput = stdinPipe
        proc.standardError = FileHandle.nullDevice

        state = .connecting
        await delegate?.controlClient(self, didChangeState: .connecting)

        try proc.run()
        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting

        let handle = stdoutPipe.fileHandleForReading
        readTask = Task.detached { [weak self, handle] in
            do {
                for try await line in handle.bytes.lines {
                    await self?.handleLine(line)
                }
            } catch {}
            await self?.handleEOF()
        }

        // Wait for initial greeting (%begin/%end)
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            commandQueue.enqueue(continuation)
        }

        state = .connected
        await delegate?.controlClient(self, didChangeState: .connected)
    }

    func disconnect() async {
        readTask?.cancel()
        readTask = nil
        process?.terminate()
        process = nil
        stdinHandle = nil
        state = .disconnected(reason: "user disconnected")
        // Drain pending continuations to avoid leaked CheckedContinuation
        while !commandQueue.isEmpty {
            commandQueue.dequeueWithError(TmuxControlError.notConnected)
        }
        await delegate?.controlClient(self, didChangeState: .disconnected(reason: "user disconnected"))
    }

    // MARK: - Commands

    func send(_ command: String) async throws -> String {
        guard let stdinHandle else {
            throw TmuxControlError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            commandQueue.enqueue(continuation)
            stdinHandle.write(Data((command + "\n").utf8))
        }
    }

    func sendFireAndForget(_ command: String) {
        guard let stdinHandle else { return }
        commandQueue.enqueue(nil)
        stdinHandle.write(Data((command + "\n").utf8))
    }

    func sendKeys(paneID: Int, data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        sendFireAndForget("send-keys -t %\(paneID) -H \(hex)")
    }

    func resizePane(paneID: Int, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        sendFireAndForget("resize-pane -t %\(paneID) -x \(width) -y \(height)")
    }

    // MARK: - Window Management

    func newWindow() async throws -> String {
        try await send("new-window")
    }

    func killWindow(windowID: Int) async throws {
        _ = try await send("kill-window -t @\(windowID)")
    }

    func renameWindow(windowID: Int, name: String) async throws {
        _ = try await send("rename-window -t @\(windowID) '\(name)'")
    }

    func splitPane(paneID: Int, horizontal: Bool) async throws {
        let flag = horizontal ? "-h" : "-v"
        _ = try await send("split-window \(flag) -t %\(paneID)")
    }

    func killPane(paneID: Int) async throws {
        _ = try await send("kill-pane -t %\(paneID)")
    }

    // MARK: - Line Handling

    private func handleLine(_ line: String) async {
        let event = parser.parse(line: line)

        if inBlock, event == nil {
            commandQueue.appendToCurrentResponse(line + "\n")
            return
        }

        guard let event else { return }

        switch event {
        case .beginBlock:
            inBlock = true

        case .endBlock:
            inBlock = false
            commandQueue.dequeue()

        case .errorBlock:
            inBlock = false
            commandQueue.dequeueWithError(TmuxControlError.serverError("tmux error"))

        case .windowAdd(let windowID):
            let window = TmuxWindow(windowID: windowID, name: "")
            windows[windowID] = window
            await delegate?.controlClient(self, didAddWindow: window)

        case .windowClose(let windowID):
            windows.removeValue(forKey: windowID)
            await delegate?.controlClient(self, didCloseWindowID: windowID)

        case .windowRenamed(let windowID, let name):
            windows[windowID]?.name = name
            await delegate?.controlClient(self, didRenameWindowID: windowID, to: name)

        case .layoutChange(let windowID, let layout):
            await delegate?.controlClient(self, didChangeLayoutForWindowID: windowID, layout: layout)

        case .output(let paneID, let data):
            await delegate?.controlClient(self, didReceiveOutput: data, forPaneID: paneID)

        case .exit(let reason):
            state = .disconnected(reason: reason)
            process?.terminate()
            process = nil
            stdinHandle = nil
            await delegate?.controlClientDidExit(self, reason: reason)

        case .sessionChanged, .sessionsChanged, .paneModeChanged, .unknown:
            break
        }
    }

    private func handleEOF() async {
        if case .disconnected = state { return }
        state = .disconnected(reason: "connection closed")
        while !commandQueue.isEmpty {
            commandQueue.dequeueWithError(TmuxControlError.processTerminated)
        }
        await delegate?.controlClientDidExit(self, reason: "connection closed")
    }

    // MARK: - Testing Support

    #if DEBUG
    func processLine(_ line: String) async {
        await handleLine(line)
    }
    #endif
}

extension TmuxControlClient: TmuxCommandSending {}
