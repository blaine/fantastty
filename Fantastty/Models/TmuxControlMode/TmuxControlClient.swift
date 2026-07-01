import Foundation
import Darwin

// MARK: - TmuxWindow

struct TmuxWindow: Sendable {
    let windowID: Int
    var name: String
    var paneIDs: Set<Int> = []
    var windowIndex: Int?
    var isActive: Bool = false
}

struct TmuxCapturedPane: Sendable, Equatable {
    let paneID: Int
    let data: Data
}

// MARK: - TmuxControlError

enum TmuxControlError: Error, Sendable {
    case notConnected
    case processTerminated
    case serverError(String)
}

extension TmuxControlError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "tmux control connection is not connected"
        case .processTerminated:
            return "tmux control process terminated"
        case .serverError(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "tmux returned an error" : trimmed
        }
    }
}

// MARK: - TmuxControlClientDelegate

@MainActor
protocol TmuxControlClientDelegate: AnyObject {
    func controlClient(_ client: TmuxControlClient, didAddWindow window: TmuxWindow)
    func controlClient(_ client: TmuxControlClient, didCloseWindowID windowID: Int)
    func controlClient(_ client: TmuxControlClient, didRenameWindowID windowID: Int, to name: String)
    func controlClient(_ client: TmuxControlClient, didChangeActiveWindowID windowID: Int)
    func controlClient(_ client: TmuxControlClient, didChangeActivePaneID paneID: Int, inWindowID windowID: Int)
    func controlClient(_ client: TmuxControlClient, didChangeLayoutForWindowID windowID: Int, layout: String)
    func controlClient(_ client: TmuxControlClient, didReceiveOutput data: Data, forPaneID paneID: Int)
    func controlClient(_ client: TmuxControlClient, didReceivePaneTitle title: String, forPaneID paneID: Int)
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

// MARK: - TmuxControlTransport

protocol TmuxControlTransport: AnyObject {
    var onLine: (@Sendable (Data) -> Void)? { get set }
    var onTermination: (@Sendable (Int32?) -> Void)? { get set }

    func start(command: String, environment: [String: String]) throws
    func write(_ data: Data) throws
    func stop()
}

final class PtyTmuxControlTransport: NSObject, TmuxControlTransport {
    var onLine: (@Sendable (Data) -> Void)?
    var onTermination: (@Sendable (Int32?) -> Void)?

    private var process: Process?
    private var masterFD: Int32 = -1
    private var readTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var didNotifyTermination = false
    /// Serial queue for PTY writes. Writing to the PTY master can block when
    /// tmux's input buffer is full (e.g. tmux is blocked writing stdout).
    /// Dispatching writes here keeps the actor's cooperative thread free to
    /// consume the read side, breaking the circular dependency.
    private let writeQueue = DispatchQueue(label: "com.fantastty.tmux-transport-write")

    func start(command: String, environment: [String: String]) throws {
        stop()

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = Self.shellArguments(for: command)
        proc.environment = environment

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle
        proc.terminationHandler = { [weak self] process in
            self?.notifyTerminationIfNeeded(status: process.terminationStatus)
        }

        do {
            try proc.run()
        } catch {
            Darwin.close(master)
            Darwin.close(slave)
            throw error
        }

        Darwin.close(slave)

        stateLock.lock()
        didNotifyTermination = false
        process = proc
        masterFD = master
        stateLock.unlock()

        readTask = Task.detached { [weak self] in
            self?.readLoop()
        }
    }

    static func shellArguments(for command: String) -> [String] {
        ["-lc", "exec \(command)"]
    }

    func write(_ data: Data) throws {
        let fd = withLockedState { masterFD }
        guard fd >= 0 else {
            throw TmuxControlError.notConnected
        }

        // Dispatch the blocking Darwin.write() to a serial background queue.
        // The actor calls transport.write() from its cooperative thread; if
        // Darwin.write() blocked inline it would prevent the actor from
        // consuming the read side of the PTY, creating a circular deadlock
        // when tmux's stdout buffer is full.
        writeQueue.async {
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var totalWritten = 0
                while totalWritten < rawBuffer.count {
                    let pointer = baseAddress.advanced(by: totalWritten)
                    let remaining = rawBuffer.count - totalWritten
                    let written = Darwin.write(fd, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return  // write error — connection will be detected by read side
                    }
                    totalWritten += written
                }
            }
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil

        if let process, process.isRunning {
            process.terminate()
        }

        // Drain pending writes before closing the fd to avoid writing to a
        // recycled file descriptor.
        writeQueue.sync {}

        withLockedState {
            if masterFD >= 0 {
                Darwin.close(masterFD)
                masterFD = -1
            }
            self.process = nil
            didNotifyTermination = true
        }
    }

    private func readLoop() {
        var buffered = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while !Task.isCancelled {
            let fd = withLockedState { masterFD }
            guard fd >= 0 else { break }

            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffered.append(contentsOf: chunk[0..<count])

                while let newlineIndex = buffered.firstIndex(of: 0x0a) {
                    let lineData = Data(buffered[..<newlineIndex])
                    buffered.removeSubrange(...newlineIndex)
                    emitLine(lineData)
                }
                continue
            }

            if count == 0 {
                break
            }

            if errno == EINTR {
                continue
            }
            break
        }

        if !buffered.isEmpty {
            emitLine(Data(buffered))
        }
    }

    private func emitLine(_ line: Data) {
        let callback = withLockedState { onLine }
        callback?(line)
    }

    private func notifyTerminationIfNeeded(status: Int32?) {
        let callback: (@Sendable (Int32?) -> Void)? = withLockedState {
            if didNotifyTermination {
                return nil
            }
            didNotifyTermination = true
            return onTermination
        }
        callback?(status)
    }

    private func withLockedState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

// MARK: - TmuxControlClient

actor TmuxControlClient {
    typealias TransportFactory = () -> any TmuxControlTransport

    private enum TransportEvent: Sendable {
        case line(Data)
        case termination(Int32?)
    }

    private enum ConnectStage: Equatable {
        case idle
        case startingTransport
        case awaitingInitialGreeting
        case awaitingReadyBlock
        case bootstrappingWindows
        case connected
        case terminating
        case disconnected
    }

    private enum InitialGreetingState {
        case idle
        case waiting
        case completed
    }

    struct SanitizedPaneOutput: Equatable {
        let data: Data
        let titles: [String]
    }

    private struct ScreenTitleSequenceSanitizer {
        private enum State {
            case normal
            case afterEscape
            case screenTitle
            case screenTitleAfterEscape
        }

        private var state: State = .normal
        private var titleBuffer = Data()

        mutating func consume(_ data: Data) -> SanitizedPaneOutput {
            var sanitized = Data()
            sanitized.reserveCapacity(data.count)
            var titles: [String] = []

            for byte in data {
                switch state {
                case .normal:
                    if byte == 0x1b {
                        state = .afterEscape
                    } else {
                        sanitized.append(byte)
                    }

                case .afterEscape:
                    if byte == 0x6b {
                        state = .screenTitle
                    } else if byte == 0x1b {
                        sanitized.append(0x1b)
                        state = .afterEscape
                    } else {
                        sanitized.append(0x1b)
                        sanitized.append(byte)
                        state = .normal
                    }

                case .screenTitle:
                    if byte == 0x1b {
                        state = .screenTitleAfterEscape
                    } else {
                        titleBuffer.append(byte)
                    }

                case .screenTitleAfterEscape:
                    if byte == 0x5c {
                        titles.append(String(decoding: titleBuffer, as: UTF8.self))
                        titleBuffer.removeAll(keepingCapacity: true)
                        state = .normal
                    } else if byte != 0x1b {
                        titleBuffer.append(0x1b)
                        titleBuffer.append(byte)
                        state = .screenTitle
                    }
                }
            }

            return SanitizedPaneOutput(data: sanitized, titles: titles)
        }

        mutating func finish() -> SanitizedPaneOutput {
            defer {
                state = .normal
                titleBuffer.removeAll(keepingCapacity: false)
            }

            switch state {
            case .afterEscape:
                return SanitizedPaneOutput(data: Data([0x1b]), titles: [])
            case .normal, .screenTitle, .screenTitleAfterEscape:
                return SanitizedPaneOutput(data: Data(), titles: [])
            }
        }
    }

    let attachmentInfo: TmuxAttachmentInfo

    nonisolated(unsafe) weak var delegate: (any TmuxControlClientDelegate)?

    private var parser = TmuxProtocolParser()
    private var commandQueue = CommandQueue()
    private var blockTracker = TmuxControlBlockTracker()
    private(set) var windows: [Int: TmuxWindow] = [:]
    private(set) var state: ConnectionState = .disconnected(reason: nil)
    private var connectStage: ConnectStage = .idle
    private let transportFactory: TransportFactory
    private var transport: (any TmuxControlTransport)?
    private var transportEventContinuation: AsyncStream<TransportEvent>.Continuation?
    private var transportEventTask: Task<Void, Never>?
    private var paneOutputSanitizers: [Int: ScreenTitleSequenceSanitizer] = [:]
    /// Pane IDs with output paused during bootstrap, awaiting deferred content capture after first resize.
    private var deferredBootstrapPaneIDs: Set<Int> = []
    private var bootstrapReadyPaneIDsBeforeOutputPaused: Set<Int> = []
    private var initialGreetingState: InitialGreetingState = .idle
    private var initialGreetingContinuation: CheckedContinuation<Void, any Error>?
    #if DEBUG
    private var debugTrace: [String] = []
    #endif

    init(
        attachmentInfo: TmuxAttachmentInfo,
        transportFactory: @escaping TransportFactory = { PtyTmuxControlTransport() }
    ) {
        self.attachmentInfo = attachmentInfo
        self.transportFactory = transportFactory
    }

    private var localTmuxPath: String {
        TmuxManager.shared.tmuxPath
    }

    private var resolvedTmuxPath: String {
        switch attachmentInfo.host {
        case .local:
            return localTmuxPath
        case .ssh:
            return "tmux"
        }
    }

    // MARK: - Connection Lifecycle

    func connect() async throws {
        #if DEBUG
        recordDebugTrace("connect:start launchMode=\(attachmentInfo.launchMode.rawValue) command=\(attachmentInfo.controlCommand(tmuxPath: resolvedTmuxPath))")
        #endif
        if attachmentInfo.launchMode == .create {
            try await createSessionBeforeAttaching()
        }

        connectStage = .startingTransport
        let command = attachmentInfo.controlCommand(tmuxPath: resolvedTmuxPath)
        var environment = ProcessInfo.processInfo.environment
        if environment["TERM"] == nil || environment["TERM"] == "dumb" {
            environment["TERM"] = "xterm-256color"
        }

        let transport = transportFactory()
        var eventContinuation: AsyncStream<TransportEvent>.Continuation?
        let eventStream = AsyncStream<TransportEvent> { continuation in
            eventContinuation = continuation
        }
        guard let eventContinuation else {
            throw TmuxControlError.serverError("failed to initialize tmux transport event stream")
        }
        transportEventContinuation = eventContinuation
        transportEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in eventStream {
                await self.handleTransportEvent(event)
            }
        }

        transport.onLine = { lineData in
            eventContinuation.yield(.line(lineData))
        }
        transport.onTermination = { status in
            eventContinuation.yield(.termination(status))
        }

        state = .connecting
        await delegate?.controlClient(self, didChangeState: .connecting)

        // tmux -C emits one spontaneous %begin/%end greeting before any commands.
        // Reserve a fire-and-forget queue slot before the reader starts so we don't
        // race and lose that block on fast local startup.
        initialGreetingState = .waiting
        commandQueue.enqueue(nil)
        connectStage = .awaitingInitialGreeting

        try transport.start(command: command, environment: environment)
        #if DEBUG
        recordDebugTrace("connect:transport-started type=\(String(describing: type(of: transport)))")
        #endif
        self.transport = transport

        #if DEBUG
        recordDebugTrace("connect:wait-initial-greeting:start")
        #endif
        try await waitForInitialGreeting()
        #if DEBUG
        recordDebugTrace("connect:initial-greeting-complete")
        #endif

        connectStage = .awaitingReadyBlock
        #if DEBUG
        recordDebugTrace("connect:ready:start")
        #endif
        _ = try await send(Self.readyCommand())
        #if DEBUG
        recordDebugTrace("connect:ready-complete")
        #endif

        // Enable extended keys so tmux generates CSI u sequences for
        // modified keys (e.g. shift-enter → \x1b[13;2u).
        _ = try await send("set-option -g extended-keys on")

        #if DEBUG
        recordDebugTrace("connect:bootstrap:start")
        #endif
        connectStage = .bootstrappingWindows
        try await bootstrapWindows()
        #if DEBUG
        recordDebugTrace("connect:bootstrap-complete windows=\(windows.keys.sorted())")
        #endif

        if attachmentInfo.launchMode == .create, windows.isEmpty {
            #if DEBUG
            recordDebugTrace("connect:create-launch-no-windows creating-initial-window")
            #endif
            _ = try await newWindow()
        }

        state = .connected
        connectStage = .connected
        await delegate?.controlClient(self, didChangeState: .connected)
    }

    private func failPendingOperations(_ error: any Error) {
        #if DEBUG
        recordDebugTrace("fail-pending error=\(error.localizedDescription)")
        #endif
        blockTracker.reset()
        if initialGreetingState == .waiting {
            initialGreetingState = .idle
            initialGreetingContinuation?.resume(throwing: error)
            initialGreetingContinuation = nil
        }
        while !commandQueue.isEmpty {
            commandQueue.dequeueWithError(error)
        }
    }

    private func createSessionBeforeAttaching() async throws {
        #if DEBUG
        recordDebugTrace("create-session:start command=\(attachmentInfo.createSessionCommand(tmuxPath: resolvedTmuxPath))")
        #endif
        let outputPipe = Pipe()
        let createProcess = Process()
        createProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        createProcess.arguments = ["-c", attachmentInfo.createSessionCommand(tmuxPath: resolvedTmuxPath)]
        createProcess.standardOutput = outputPipe
        createProcess.standardError = outputPipe

        var environment = ProcessInfo.processInfo.environment
        if environment["TERM"] == nil || environment["TERM"] == "dumb" {
            environment["TERM"] = "xterm-256color"
        }
        createProcess.environment = environment

        try createProcess.run()
        createProcess.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard createProcess.terminationStatus == 0 else {
            let message = String(decoding: outputData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TmuxControlError.serverError(message.isEmpty ? "tmux create-session failed" : message)
        }
        #if DEBUG
        recordDebugTrace("create-session:complete")
        #endif
    }

    private func waitForInitialGreeting() async throws {
        if initialGreetingState == .completed {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            initialGreetingContinuation = continuation
        }
    }

    /// Query tmux for existing windows and notify the delegate about each one.
    private func bootstrapWindows() async throws {
        let response = try await send(
            "list-windows -F '#{window_id}\t#{window_name}\t#{window_layout}\t#{window_index}\t#{window_active}'"
        )

        var bootstrappedWindows: [(window: TmuxWindow, layout: String, paneIDs: [Int])] = []

        // tmux control-mode command blocks may be newline-delimited with LF,
        // CRLF, or CR depending on transport/PTY settings. Treat any newline
        // scalar as a record separator.
        for rawLine in response.split(whereSeparator: \.isNewline) {
            guard let parsed = Self.parseBootstrapWindowLine(String(rawLine)) else {
                continue
            }

            let windowID = parsed.window.windowID
            let layout = parsed.layout

            let layoutNode = TmuxLayoutParser.parse(layout)
            var window = parsed.window
            window.paneIDs = Set(layoutNode.allPaneIDs())
            windows[windowID] = window

            bootstrappedWindows.append(
                (window: window, layout: layout, paneIDs: layoutNode.allPaneIDs())
            )
        }

        for entry in bootstrappedWindows {
            await delegate?.controlClient(self, didAddWindow: entry.window)
        }

        for entry in bootstrappedWindows {
            await delegate?.controlClient(
                self,
                didChangeLayoutForWindowID: entry.window.windowID,
                layout: entry.layout
            )
        }

        let paneIDs = Array(
            Set(
                bootstrappedWindows
                    .flatMap(\.paneIDs)
            )
        ).sorted()
        if !paneIDs.isEmpty {
            // Pause %output delivery so tmux keeps its pane state current
            // without sending raw startup bytes before the first correctly
            // sized capture.
            _ = try await send(Self.clientPaneOutputStateCommand(paneIDs: paneIDs, state: "pause"))
            deferredBootstrapPaneIDs = Set(paneIDs)
            let readyPaneIDs = Array(bootstrapReadyPaneIDsBeforeOutputPaused.intersection(deferredBootstrapPaneIDs)).sorted()
            bootstrapReadyPaneIDsBeforeOutputPaused.subtract(readyPaneIDs)
            if !readyPaneIDs.isEmpty {
                await continueDeferredBootstrap(paneIDs: readyPaneIDs)
            }
        }
    }

    private func bootstrapPaneContent(for paneIDs: [Int]) async throws {
        let captured = try await capturePaneContents(paneIDs: paneIDs)
        for pane in captured {
            await delegate?.controlClient(self, didReceiveOutput: pane.data, forPaneID: pane.paneID)
        }
    }

    /// Complete the deferred bootstrap: capture pane content at the correct size, then resume %output.
    /// Called after the first resize is sent so content is captured at the right dimensions.
    /// Returns the subset of `paneIDs` that are currently awaiting deferred bootstrap.
    func deferredBootstrapPanes(among paneIDs: [Int]) -> [Int] {
        paneIDs.filter { deferredBootstrapPaneIDs.contains($0) }
    }

    func continueDeferredBootstrap(paneIDs: [Int]) async {
        let toCapture = paneIDs.filter { deferredBootstrapPaneIDs.contains($0) }
        guard !toCapture.isEmpty else {
            if connectStage == .bootstrappingWindows {
                bootstrapReadyPaneIDsBeforeOutputPaused.formUnion(paneIDs)
            }
            return
        }

        do {
            try await bootstrapPaneContent(for: toCapture)
        } catch {}

        // Drop paused raw startup output before re-enabling live %output.
        let toContinue = toCapture.filter { deferredBootstrapPaneIDs.contains($0) }
        guard !toContinue.isEmpty else { return }
        deferredBootstrapPaneIDs.subtract(toContinue)
        _ = try? await send(Self.clientPaneOutputStateCommand(paneIDs: toContinue, state: "off"))
        _ = try? await send(Self.clientPaneOutputStateCommand(paneIDs: toContinue, state: "on"))
    }

    func disconnect() async {
        connectStage = .terminating
        transport?.stop()
        transport = nil
        stopTransportEventPump()
        state = .disconnected(reason: "user disconnected")
        connectStage = .disconnected
        failPendingOperations(TmuxControlError.notConnected)
        await delegate?.controlClient(self, didChangeState: .disconnected(reason: "user disconnected"))
    }

    // MARK: - Commands

    func send(_ command: String) async throws -> String {
        guard let transport else {
            throw TmuxControlError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            commandQueue.enqueue(continuation)
            // Write errors are detected by the read side (transport termination).
            // The write itself is dispatched to a background queue to avoid
            // blocking the actor.
            try? transport.write(Data((command + "\n").utf8))
        }
    }

    func sendFireAndForget(_ command: String) {
        guard let transport else { return }
        commandQueue.enqueue(nil)
        try? transport.write(Data((command + "\n").utf8))
    }

    func sendKeys(paneID: Int, data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        sendFireAndForget("send-keys -t %\(paneID) -H \(hex)")
    }

    func refreshClientSize(windowID: Int?, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        sendFireAndForget(Self.clientSizeCommand(windowID: windowID, width: width, height: height))
    }

    /// Tells tmux the exact grid size of a single pane.
    /// Fire-and-forget: errors are silently ignored.
    func resizePane(paneID: Int, columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        sendFireAndForget(Self.resizePaneCommand(paneID: paneID, columns: columns, rows: rows))
    }

    func capturePaneContents(paneIDs: [Int]) async throws -> [TmuxCapturedPane] {
        var captured: [TmuxCapturedPane] = []
        for paneID in paneIDs {
            let alternateScreenResponse = try await send(Self.alternateScreenStateCommand(paneID: paneID))
            let useAlternateScreen = Self.parseAlternateScreenState(from: alternateScreenResponse)
            let response = try await send(Self.capturePaneCommand(paneID: paneID))
            let cursorResponse = try await send(Self.capturePaneCursorCommand(paneID: paneID))
            let cursor = Self.parseCapturePaneCursor(from: cursorResponse)
            let data = Self.capturePaneReplayData(
                from: Self.capturePaneData(from: response),
                cursorX: cursor?.x ?? 0,
                cursorY: cursor?.y ?? 0,
                useAlternateScreen: useAlternateScreen
            )
            captured.append(TmuxCapturedPane(paneID: paneID, data: data))
        }
        return captured
    }

    // MARK: - Window Management

    func newWindow() async throws -> String {
        let response = try await send("new-window")
        try await bootstrapCurrentWindow()
        return response
    }

    func selectWindow(windowID: Int) {
        sendFireAndForget("select-window -t @\(windowID)")
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

    private func handleTransportEvent(_ event: TransportEvent) async {
        switch event {
        case .line(let lineData):
            await handleLine(lineData)
        case .termination(let status):
            await handleTransportTermination(status: status)
        }
    }

    private func stopTransportEventPump() {
        transportEventContinuation?.finish()
        transportEventContinuation = nil
        transportEventTask?.cancel()
        transportEventTask = nil
    }

    private func handleLine(_ lineData: Data) async {
        // Convert to String for protocol parsing (all non-%output lines are ASCII).
        // The raw Data is passed to the parser for %output lines to avoid lossy
        // UTF-8 conversion of high bytes in the payload.
        let line = String(decoding: lineData, as: UTF8.self)
        #if DEBUG
        recordDebugTrace("line:\(line)")
        #endif
        let event = parser.parse(lineData: lineData)

        if blockTracker.hasActiveBlock {
            switch event {
            case .endBlock(let id, let flags):
                let response: String
                do {
                    response = try blockTracker.end(id: id, flags: flags)
                } catch {
                    await handleProtocolViolation(error)
                    return
                }

                commandQueue.setCurrentResponse(response)
                commandQueue.dequeue()
                if initialGreetingState == .waiting {
                    initialGreetingState = .completed
                    initialGreetingContinuation?.resume()
                    initialGreetingContinuation = nil
                }
                #if DEBUG
                recordDebugTrace("event:end id=\(id) flags=\(flags)")
                #endif
                return

            case .errorBlock(let id, let flags):
                let response: String
                do {
                    response = try blockTracker.error(id: id, flags: flags)
                } catch {
                    await handleProtocolViolation(error)
                    return
                }

                let message = response.trimmingCharacters(in: .whitespacesAndNewlines)
                let errorMessage = message.isEmpty ? "tmux error" : message
                let error = TmuxControlError.serverError(errorMessage)
                commandQueue.dequeueWithError(error)
                if initialGreetingState == .waiting {
                    initialGreetingState = .idle
                    initialGreetingContinuation?.resume(throwing: error)
                    initialGreetingContinuation = nil
                }
                #if DEBUG
                recordDebugTrace("event:error-block id=\(id) flags=\(flags) message=\(errorMessage)")
                #endif
                return

            default:
                // tmux control-mode spec guarantees notifications never occur
                // inside output blocks. Preserve all other `%...` lines as
                // payload text (for example shell output that begins with `%`).
                blockTracker.append(line + "\n")
                return
            }
        }

        guard let event else { return }

        switch event {
        case .beginBlock(let id, let flags):
            do {
                try blockTracker.begin(id: id, flags: flags)
            } catch {
                await handleProtocolViolation(error)
                return
            }
            #if DEBUG
            recordDebugTrace("event:begin id=\(id) flags=\(flags)")
            #endif

        case .endBlock(let id, let flags):
            let response: String
            do {
                response = try blockTracker.end(id: id, flags: flags)
            } catch {
                // Block tracker out of sync — dequeue the pending command
                // with whatever we have rather than killing the connection.
                commandQueue.dequeue()
                if initialGreetingState == .waiting {
                    initialGreetingState = .completed
                    initialGreetingContinuation?.resume()
                    initialGreetingContinuation = nil
                }
                #if DEBUG
                recordDebugTrace("event:end-no-begin id=\(id) flags=\(flags)")
                #endif
                return
            }

            commandQueue.setCurrentResponse(response)
            commandQueue.dequeue()
            if initialGreetingState == .waiting {
                initialGreetingState = .completed
                initialGreetingContinuation?.resume()
                initialGreetingContinuation = nil
            }
            #if DEBUG
            recordDebugTrace("event:end id=\(id) flags=\(flags)")
            #endif

        case .errorBlock(let id, let flags):
            let response: String
            do {
                response = try blockTracker.error(id: id, flags: flags)
            } catch {
                // Some tmux versions send %error without a preceding %begin.
                // Treat as a command error rather than a fatal protocol violation.
                let cmdError = TmuxControlError.serverError("tmux error (command \(id))")
                commandQueue.dequeueWithError(cmdError)
                if initialGreetingState == .waiting {
                    initialGreetingState = .idle
                    initialGreetingContinuation?.resume(throwing: cmdError)
                    initialGreetingContinuation = nil
                }
                #if DEBUG
                recordDebugTrace("event:error-block-no-begin id=\(id) flags=\(flags)")
                #endif
                return
            }

            let message = response.trimmingCharacters(in: .whitespacesAndNewlines)
            let errorMessage = message.isEmpty ? "tmux error" : message
            let error = TmuxControlError.serverError(errorMessage)
            commandQueue.dequeueWithError(error)
            if initialGreetingState == .waiting {
                initialGreetingState = .idle
                initialGreetingContinuation?.resume(throwing: error)
                initialGreetingContinuation = nil
            }
            #if DEBUG
            recordDebugTrace("event:error-block id=\(id) flags=\(flags) message=\(errorMessage)")
            #endif

        case .windowAdd(let windowID):
            let window = TmuxWindow(windowID: windowID, name: "")
            windows[windowID] = window
            await delegate?.controlClient(self, didAddWindow: window)
            #if DEBUG
            recordDebugTrace("event:window-add id=\(windowID)")
            #endif

        case .windowClose(let windowID),
             .unlinkedWindowClose(let windowID):
            windows.removeValue(forKey: windowID)
            await delegate?.controlClient(self, didCloseWindowID: windowID)

        case .windowRenamed(let windowID, let name):
            windows[windowID]?.name = name
            await delegate?.controlClient(self, didRenameWindowID: windowID, to: name)

        case .sessionWindowChanged(_, let windowID):
            for key in windows.keys {
                windows[key]?.isActive = (key == windowID)
            }
            await delegate?.controlClient(self, didChangeActiveWindowID: windowID)

        case .windowPaneChanged(let windowID, let paneID):
            await delegate?.controlClient(self, didChangeActivePaneID: paneID, inWindowID: windowID)

        case .layoutChange(let windowID, let layout, _, _):
            // Update tracked pane IDs from the layout descriptor
            let layoutNode = TmuxLayoutParser.parse(layout)
            windows[windowID]?.paneIDs = Set(layoutNode.allPaneIDs())
            await delegate?.controlClient(self, didChangeLayoutForWindowID: windowID, layout: layout)
            #if DEBUG
            recordDebugTrace("event:layout-change id=\(windowID) layout=\(layout)")
            #endif

        case .output(let paneID, let data):
            let sanitized = sanitizeLivePaneOutput(data, paneID: paneID)
            for title in sanitized.titles {
                await delegate?.controlClient(self, didReceivePaneTitle: title, forPaneID: paneID)
            }
            guard !sanitized.data.isEmpty else { return }
            await delegate?.controlClient(self, didReceiveOutput: sanitized.data, forPaneID: paneID)

        case .exit(let reason):
            let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
            let exitReason = (trimmedReason?.isEmpty == false) ? trimmedReason : nil
            connectStage = .terminating
            state = .disconnected(reason: exitReason)
            connectStage = .disconnected
            transport?.stop()
            transport = nil
            stopTransportEventPump()
            failPendingOperations(
                TmuxControlError.serverError(exitReason ?? "tmux control connection exited")
            )
            await delegate?.controlClientDidExit(self, reason: exitReason)
            #if DEBUG
            recordDebugTrace("event:exit reason=\(exitReason ?? "nil")")
            #endif

        case .sessionChanged,
             .sessionsChanged,
             .clientDetached,
             .clientSessionChanged,
             .configError,
             .continued,
             .message,
             .pasteBufferChanged,
             .pasteBufferDeleted,
             .pause,
             .paneModeChanged,
             .sessionRenamed,
             .subscriptionChanged,
             .unlinkedWindowAdd,
             .unlinkedWindowRenamed,
             .unknown:
            break
        }
    }

    private func bootstrapCurrentWindow() async throws {
        let response = try await send(Self.currentWindowInfoCommand())
        #if DEBUG
        recordDebugTrace("bootstrap-current-window:response=\(response)")
        #endif
        guard let parsed = Self.parseBootstrapWindowLine(response.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return
        }

        let windowID = parsed.window.windowID
        let layoutNode = TmuxLayoutParser.parse(parsed.layout)
        var window = parsed.window
        window.paneIDs = Set(layoutNode.allPaneIDs())
        windows[windowID] = window

        await delegate?.controlClient(self, didAddWindow: window)
        await delegate?.controlClient(self, didChangeLayoutForWindowID: windowID, layout: parsed.layout)
    }

    private func handleProtocolViolation(_ error: any Error) async {
        let violation = TmuxControlError.serverError("tmux protocol violation: \(error.localizedDescription)")
        #if DEBUG
        recordDebugTrace("event:protocol-violation \(error.localizedDescription)")
        #endif
        connectStage = .terminating
        state = .disconnected(reason: violation.localizedDescription)
        connectStage = .disconnected
        transport?.stop()
        transport = nil
        stopTransportEventPump()
        failPendingOperations(violation)
        await delegate?.controlClientDidExit(self, reason: violation.localizedDescription)
    }

    private func handleTransportTermination(status: Int32?) async {
        if case .disconnected = state { return }
        #if DEBUG
        recordDebugTrace("event:transport-terminated status=\(status.map(String.init) ?? "nil")")
        #endif
        connectStage = .terminating
        transport?.stop()
        transport = nil
        stopTransportEventPump()

        let reason: String
        if let status {
            reason = "connection closed (\(status))"
        } else {
            reason = "connection closed"
        }

        state = .disconnected(reason: reason)
        connectStage = .disconnected
        failPendingOperations(TmuxControlError.processTerminated)
        await delegate?.controlClientDidExit(self, reason: reason)
    }

    static func parseBootstrapWindowLine(_ line: String) -> (window: TmuxWindow, layout: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 5 else { return nil }

        let idField = String(parts[0])
        let idString = idField.hasPrefix("@") ? String(idField.dropFirst()) : idField
        guard let windowID = Int(idString) else { return nil }

        let name = String(parts[1])
        let layout = String(parts[2])
        let windowIndex: Int? = parts.count == 5 ? Int(parts[3]) : nil
        let isActive = parts.count == 5 ? String(parts[4]) == "1" : false

        return (
            TmuxWindow(
                windowID: windowID,
                name: name,
                paneIDs: [],
                windowIndex: windowIndex,
                isActive: isActive
            ),
            layout
        )
    }

    static func capturePaneCommand(paneID: Int) -> String {
        // Keep wrapped lines as separate rows so replay matches pane geometry.
        return "capture-pane -p -e -t %\(paneID)"
    }

    static func currentWindowInfoCommand() -> String {
        "display-message -p '#{window_id}\t#{window_name}\t#{window_layout}\t#{window_index}\t#{window_active}'"
    }

    static func readyCommand() -> String {
        "display-message -p ready"
    }

    static func capturePaneCursorCommand(paneID: Int) -> String {
        // tmux emits literal "\t" when requested in format strings under control mode.
        // Use a plain space delimiter to avoid ambiguity and simplify parsing.
        "display-message -p -t %\(paneID) '#{cursor_x} #{cursor_y}'"
    }

    static func alternateScreenStateCommand(paneID: Int) -> String {
        "display-message -p -t %\(paneID) '#{alternate_on}'"
    }

    static func clientSizeCommand(windowID: Int?, width: Int, height: Int) -> String {
        if let windowID {
            return "refresh-client -C @\(windowID):\(width)x\(height)"
        }
        return "refresh-client -C \(width)x\(height)"
    }

    static func resizePaneCommand(paneID: Int, columns: Int, rows: Int) -> String {
        "resize-pane -t %\(paneID) -x \(columns) -y \(rows)"
    }

    static func clientPaneOutputStateCommand(paneIDs: [Int], state: String) -> String {
        // In control mode, pane IDs for -A must be quoted to avoid parser errors.
        let flags = paneIDs.map { "-A '%\($0):\(state)'" }.joined(separator: " ")
        return "refresh-client \(flags)"
    }

    static func capturePaneData(from response: String) -> Data {
        Data(response.utf8)
    }

    static func safeReadChunk(from handle: FileHandle, maxLength: Int = 4096) -> Data? {
        do {
            return try handle.read(upToCount: maxLength)
        } catch {
            return nil
        }
    }

    static func parseCapturePaneCursor(from response: String) -> (x: Int, y: Int)? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept both the current "x y" response and older/literal "\t" separators.
        let normalized = trimmed.replacingOccurrences(of: "\\t", with: " ")
        let parts = normalized.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2,
              let x = Int(parts[0]),
              let y = Int(parts[1]) else {
            return nil
        }
        return (x, y)
    }

    static func parseAlternateScreenState(from response: String) -> Bool {
        response.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    static func sanitizePaneOutput(_ data: Data) -> Data {
        sanitizePaneOutputWithTitles(data).data
    }

    static func sanitizePaneOutputWithTitles(_ data: Data) -> SanitizedPaneOutput {
        var sanitizer = ScreenTitleSequenceSanitizer()
        let consumed = sanitizer.consume(data)
        let finished = sanitizer.finish()
        let stripped = stripPromptEOLMarkerSequences(in: consumed.data + finished.data)
        return SanitizedPaneOutput(
            data: stripped,
            titles: consumed.titles + finished.titles
        )
    }

    private static func stripPromptEOLMarkerSequences(in data: Data) -> Data {
        let markerPrefix: [UInt8] = [
            0x1b, 0x5b, 0x31, 0x6d, // ESC[1m
            0x1b, 0x5b, 0x37, 0x6d, // ESC[7m
            0x25,                   // %
            0x1b, 0x5b, 0x32, 0x37, 0x6d, // ESC[27m
            0x1b, 0x5b, 0x31, 0x6d, // ESC[1m
            0x1b, 0x5b, 0x30, 0x6d, // ESC[0m
        ]

        let bytes = Array(data)
        var sanitized: [UInt8] = []
        sanitized.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            let remaining = bytes.count - index
            if remaining >= markerPrefix.count,
               Array(bytes[index..<(index + markerPrefix.count)]) == markerPrefix {
                var cursor = index + markerPrefix.count
                while cursor < bytes.count, bytes[cursor] == 0x20 {
                    cursor += 1
                }

                if cursor + 2 < bytes.count,
                   bytes[cursor] == 0x0D,
                   bytes[cursor + 1] == 0x20,
                   bytes[cursor + 2] == 0x0D {
                    index = cursor + 3
                    continue
                }
            }

            sanitized.append(bytes[index])
            index += 1
        }

        return Data(sanitized)
    }

    static func capturePaneReplayData(
        from data: Data,
        cursorX: Int,
        cursorY: Int,
        useAlternateScreen: Bool = false
    ) -> Data {
        let sanitized = sanitizePaneOutput(data)
        // Always start from a known frame; tmux capture data is a full-screen snapshot.
        // Clearing here prevents stale glyphs from prior frames during bootstrap/recapture.
        var replay = Data()
        if useAlternateScreen {
            replay.append(Data("\u{1b}[?1049h".utf8))
        }
        replay.append(Data("\u{1b}[H\u{1b}[2J".utf8))
        var normalized = normalizeCapturedPaneLineEndings(in: sanitized)
        trimTrailingCapturedRowSeparator(in: &normalized)
        replay.append(normalized)

        let row = max(cursorY + 1, 1)
        let column = max(cursorX + 1, 1)
        replay.append(Data("\u{1b}[\(row);\(column)H".utf8))
        return replay
    }

    private static func trimTrailingCapturedRowSeparator(in data: inout Data) {
        guard !data.isEmpty else { return }
        if data.count >= 2,
           data[data.index(data.endIndex, offsetBy: -2)] == 0x0D,
           data[data.index(before: data.endIndex)] == 0x0A {
            data.removeLast(2)
            return
        }

        if let last = data.last, last == 0x0D || last == 0x0A {
            data.removeLast()
        }
    }

    private static func normalizeCapturedPaneLineEndings(in data: Data) -> Data {
        var normalized = Data()
        normalized.reserveCapacity(data.count + 32)
        var previousByte: UInt8?

        for byte in data {
            if byte == 0x0A {
                if previousByte != 0x0D {
                    normalized.append(0x0D)
                }
                normalized.append(0x0A)
            } else {
                normalized.append(byte)
            }
            previousByte = byte
        }

        return normalized
    }

    private func sanitizeLivePaneOutput(_ data: Data, paneID: Int) -> SanitizedPaneOutput {
        var sanitizer = paneOutputSanitizers[paneID] ?? ScreenTitleSequenceSanitizer()
        let sanitized = sanitizer.consume(data)
        paneOutputSanitizers[paneID] = sanitizer
        return sanitized
    }

    // MARK: - Testing Support

    #if DEBUG
    private func recordDebugTrace(_ entry: String) {
        debugTrace.append(entry)
    }

    func currentDebugTrace() -> [String] {
        debugTrace
    }

    func processLine(_ line: String) async {
        await handleLine(Data(line.utf8))
    }

    func emitBootstrapPaneContent(_ response: String, paneID: Int) async {
        let data = Self.capturePaneReplayData(from: Self.capturePaneData(from: response), cursorX: 0, cursorY: 0)
        await delegate?.controlClient(self, didReceiveOutput: data, forPaneID: paneID)
    }

    func beginWaitingForInitialGreetingForTests() {
        initialGreetingState = .waiting
    }

    func beginInitialGreetingBlockForTests() {
        initialGreetingState = .waiting
        commandQueue.enqueue(nil)
    }

    func waitForInitialGreetingForTests() async throws {
        try await waitForInitialGreeting()
    }

    func hasPendingInitialGreetingWaitForTests() -> Bool {
        initialGreetingState == .waiting && initialGreetingContinuation != nil
    }
    #endif
}

extension TmuxControlClient: TmuxCommandSending {}
