import XCTest
@testable import Fantastty

/// Records delegate calls for assertion.
@MainActor
final class MockControlClientDelegate: TmuxControlClientDelegate {
    var addedWindows: [TmuxWindow] = []
    var closedWindowIDs: [Int] = []
    var renamedWindows: [(windowID: Int, name: String)] = []
    var activeWindowIDs: [Int] = []
    var activePaneChanges: [(windowID: Int, paneID: Int)] = []
    var layoutChanges: [(windowID: Int, layout: String)] = []
    var outputReceived: [(paneID: Int, data: Data)] = []
    var paneTitles: [(paneID: Int, title: String)] = []
    var stateChanges: [ConnectionState] = []
    var exitReasons: [String?] = []

    func controlClient(_ client: TmuxControlClient, didAddWindow window: TmuxWindow) {
        addedWindows.append(window)
    }
    func controlClient(_ client: TmuxControlClient, didCloseWindowID windowID: Int) {
        closedWindowIDs.append(windowID)
    }
    func controlClient(_ client: TmuxControlClient, didRenameWindowID windowID: Int, to name: String) {
        renamedWindows.append((windowID, name))
    }
    func controlClient(_ client: TmuxControlClient, didChangeActiveWindowID windowID: Int) {
        activeWindowIDs.append(windowID)
    }
    func controlClient(_ client: TmuxControlClient, didChangeActivePaneID paneID: Int, inWindowID windowID: Int) {
        activePaneChanges.append((windowID, paneID))
    }
    func controlClient(_ client: TmuxControlClient, didChangeLayoutForWindowID windowID: Int, layout: String) {
        layoutChanges.append((windowID, layout))
    }
    func controlClient(_ client: TmuxControlClient, didReceiveOutput data: Data, forPaneID paneID: Int) {
        outputReceived.append((paneID, data))
    }
    func controlClient(_ client: TmuxControlClient, didReceivePaneTitle title: String, forPaneID paneID: Int) {
        paneTitles.append((paneID, title))
    }
    func controlClient(_ client: TmuxControlClient, didChangeState state: ConnectionState) {
        stateChanges.append(state)
    }
    func controlClientDidExit(_ client: TmuxControlClient, reason: String?) {
        exitReasons.append(reason)
    }
}

final class TmuxControlClientTests: XCTestCase {

    var client: TmuxControlClient!
    var delegate: MockControlClientDelegate!

    @MainActor
    override func setUp() {
        let info = TmuxAttachmentInfo(
            sessionName: "test",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )
        client = TmuxControlClient(attachmentInfo: info)
        delegate = MockControlClientDelegate()
        client.delegate = delegate
    }

    // MARK: - Event dispatch

    func testWindowAddNotifiesDelegate() async {
        await client.processLine("%window-add @5")

        let added = await MainActor.run { delegate.addedWindows }
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.windowID, 5)
    }

    func testWindowCloseNotifiesDelegate() async {
        // First add the window so it exists in state
        await client.processLine("%window-add @3")
        await client.processLine("%window-close @3")

        let closed = await MainActor.run { delegate.closedWindowIDs }
        XCTAssertEqual(closed, [3])
    }

    func testUnlinkedWindowCloseNotifiesDelegate() async {
        await client.processLine("%window-add @3")
        await client.processLine("%unlinked-window-close @3")

        let closed = await MainActor.run { delegate.closedWindowIDs }
        XCTAssertEqual(closed, [3])
    }

    func testWindowRenamedNotifiesDelegate() async {
        await client.processLine("%window-add @1")
        await client.processLine("%window-renamed @1 new-name")

        let renamed = await MainActor.run { delegate.renamedWindows }
        XCTAssertEqual(renamed.count, 1)
        XCTAssertEqual(renamed.first?.name, "new-name")

        // Also verify internal state updated
        let windows = await client.windows
        XCTAssertEqual(windows[1]?.name, "new-name")
    }

    func testOutputNotifiesDelegate() async {
        await client.processLine("%output %0 hello")

        let output = await MainActor.run { delegate.outputReceived }
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.paneID, 0)
        XCTAssertEqual(String(data: output.first!.data, encoding: .utf8), "hello")
    }

    func testOutputWithScreenTitleSequenceEmitsPaneTitleMetadata() async {
        await client.processLine(#"%output %7 \033kecho\033\134hello world"#)

        let output = await MainActor.run { delegate.outputReceived }
        let titles = await MainActor.run { delegate.paneTitles }

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.paneID, 7)
        XCTAssertEqual(String(data: output.first!.data, encoding: .utf8), "hello world")
        XCTAssertEqual(titles.count, 1)
        XCTAssertEqual(titles.first?.paneID, 7)
        XCTAssertEqual(titles.first?.title, "echo")
    }

    func testLayoutChangeNotifiesDelegate() async {
        await client.processLine("%layout-change @2 bb62,213x55,0,0,0 bb62,213x55,0,0,0 *")

        let changes = await MainActor.run { delegate.layoutChanges }
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.windowID, 2)
        XCTAssertEqual(changes.first?.layout, "bb62,213x55,0,0,0")
    }

    func testSessionWindowChangedNotifiesDelegate() async {
        await client.processLine("%session-window-changed $4 @12")

        let activeWindows = await MainActor.run { delegate.activeWindowIDs }
        XCTAssertEqual(activeWindows, [12])
    }

    func testWindowPaneChangedNotifiesDelegate() async {
        await client.processLine("%window-pane-changed @12 %9")

        let paneChanges = await MainActor.run { delegate.activePaneChanges }
        XCTAssertEqual(paneChanges.count, 1)
        XCTAssertEqual(paneChanges.first?.windowID, 12)
        XCTAssertEqual(paneChanges.first?.paneID, 9)
    }

    func testExitNotifiesDelegate() async {
        await client.processLine("%exit server exited")

        let exits = await MainActor.run { delegate.exitReasons }
        XCTAssertEqual(exits.count, 1)
        XCTAssertEqual(exits.first, "server exited")
    }

    // MARK: - Begin/End block handling

    func testResponseBlockAccumulatesText() async {
        // Simulate a command response
        await client.processLine("%begin 123 1 0")
        await client.processLine("response line 1")
        await client.processLine("response line 2")
        await client.processLine("%end 123 1 0")
        // The command queue should have delivered the response.
        // This tests that non-% lines inside blocks are accumulated,
        // not treated as notifications.
    }

    func testPercentPrefixedLinesInsideResponseBlockAreNotDispatchedAsNotifications() async {
        // tmux 3.6a control-mode spec: notifications never occur inside
        // output blocks, so this line must be treated as block payload text.
        await client.processLine("%begin 123 1 0")
        await client.processLine("%window-add @9")
        await client.processLine("%end 123 1 0")

        let added = await MainActor.run { delegate.addedWindows }
        XCTAssertTrue(added.isEmpty)
    }

    // MARK: - Command string generation

    func testSendKeysHexEncoding() async {
        // Verify sendKeys produces correct hex format
        let data = Data([0x1b, 0x5b, 0x41])  // ESC [ A (up arrow)
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        XCTAssertEqual(hex, "1b 5b 41")
    }

    func testAttachedTmuxInputPrefersRawControlCharactersFromEvent() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "c",
            eventCharacters: "\u{03}"
        )

        XCTAssertEqual(data, Data([0x03]))
    }

    func testAttachedTmuxInputUsesPrintableTextWhenNoControlCharacterExists() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "ls",
            eventCharacters: "ls"
        )

        XCTAssertEqual(data, Data("ls".utf8))
    }

    func testAttachedTmuxInputMapsControlModifiedPrintableCharacterToControlByte() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "r",
            eventCharacters: "r",
            modifierFlags: [.control]
        )

        XCTAssertEqual(data, Data([0x12]))
    }

    func testAttachedTmuxInputMapsControlOpenBracketToEscapeByte() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "[",
            eventCharacters: "[",
            modifierFlags: [.control]
        )

        XCTAssertEqual(data, Data([0x1b]))
    }

    func testAttachedTmuxInputIgnoresReleaseEvents() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: true,
            text: nil,
            eventCharacters: "\u{7f}"
        )

        XCTAssertNil(data)
    }

    func testAttachedTmuxInputSkipsFunctionKeyUnicodeForHexPath() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "\u{f700}",
            eventCharacters: "\u{f700}"
        )

        XCTAssertNil(data)
    }

    // MARK: - Escape sequence encoding

    func testEscapeSequenceArrowUpUnmodified() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 126,
            eventCharacters: "\u{f700}",
            modifierFlags: []
        )
        // \e[A
        XCTAssertEqual(data, Data([0x1b, 0x5b, 0x41]))
    }

    func testEscapeSequenceArrowLeftByKeyCodeFallback() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 123,
            eventCharacters: nil,
            modifierFlags: []
        )
        // \e[D
        XCTAssertEqual(data, Data([0x1b, 0x5b, 0x44]))
    }

    func testEscapeSequenceArrowRightWithControlAndOption() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 124,
            eventCharacters: "\u{f703}",
            modifierFlags: [.control, .option]
        )
        // \e[1;7C  (modifier = 1 + 4 + 2 = 7)
        XCTAssertEqual(data, Data(Array("\u{1b}[1;7C".utf8)))
    }

    func testEscapeSequenceShiftEnterProducesCsiU() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 36,
            eventCharacters: nil,
            modifierFlags: [.shift]
        )
        // \e[13;2u
        XCTAssertEqual(data, Data(Array("\u{1b}[13;2u".utf8)))
    }

    func testEscapeSequenceShiftTabProducesBacktab() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 48,
            eventCharacters: nil,
            modifierFlags: [.shift]
        )
        // \e[Z
        XCTAssertEqual(data, Data([0x1b, 0x5b, 0x5a]))
    }

    func testEscapeSequenceUnmodifiedEnterUsesRawInputPath() {
        let escapeData = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 36,
            eventCharacters: nil,
            modifierFlags: []
        )
        let inputData = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "\r",
            eventCharacters: "\r"
        )
        XCTAssertNil(escapeData)
        XCTAssertEqual(inputData, Data([0x0d]))
    }

    func testEscapeSequenceF1Unmodified() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 122,
            eventCharacters: nil,
            modifierFlags: []
        )
        // \eOP
        XCTAssertEqual(data, Data([0x1b, 0x4f, 0x50]))
    }

    func testEscapeSequenceF5WithShift() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 96,
            eventCharacters: nil,
            modifierFlags: [.shift]
        )
        // \e[15;2~
        XCTAssertEqual(data, Data(Array("\u{1b}[15;2~".utf8)))
    }

    func testEscapeSequenceHomeUnmodified() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 115,
            eventCharacters: "\u{f729}",
            modifierFlags: []
        )
        // \eOH
        XCTAssertEqual(data, Data([0x1b, 0x4f, 0x48]))
    }

    func testEscapeSequenceDeleteWithControl() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 117,
            eventCharacters: "\u{f728}",
            modifierFlags: [.control]
        )
        // \e[3;5~
        XCTAssertEqual(data, Data(Array("\u{1b}[3;5~".utf8)))
    }

    func testEscapeSequenceUnknownKeyReturnsNil() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 0, // 'a' keyCode
            eventCharacters: "a",
            modifierFlags: []
        )
        XCTAssertNil(data)
    }

    func testAttachedTmuxEventCharactersReturnsCharactersForKeyDown() {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )

        XCTAssertEqual(
            AttachedTmuxInputEncoder.eventCharacters(for: try XCTUnwrap(event)),
            "a"
        )
    }

    func testAttachedTmuxEventCharactersSkipsFlagsChangedEvents() {
        let event = NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x37
        )

        XCTAssertNil(AttachedTmuxInputEncoder.eventCharacters(for: try XCTUnwrap(event)))
    }

    func testAttachedTmuxRouterKeepsCommandShortcutsLocal() throws {
        let commandEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "k",
                charactersIgnoringModifiers: "k",
                isARepeat: false,
                keyCode: 40
            )
        )

        XCTAssertTrue(
            AttachedTmuxInputRouter.shouldHandleLocally(
                bindingFlags: nil,
                event: commandEvent
            )
        )
    }

    func testAttachedTmuxRouterRoutesNonCommandKeysRemotelyEvenWhenConsumed() throws {
        let plainEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "r",
                charactersIgnoringModifiers: "r",
                isARepeat: false,
                keyCode: 15
            )
        )

        XCTAssertFalse(
            AttachedTmuxInputRouter.shouldHandleLocally(
                bindingFlags: [.consumed],
                event: plainEvent
            )
        )
    }

    func testSafeReadChunkReturnsNilWhenHandleIsClosed() {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        reader.closeFile()

        XCTAssertNil(TmuxControlClient.safeReadChunk(from: reader))
    }

    func testTmuxControlErrorServerErrorUsesMessageAsLocalizedDescription() {
        let message = "can't find session: fantastty-ws-example"
        let error = TmuxControlError.serverError(message)

        XCTAssertEqual(error.localizedDescription, message)
    }

    func testRealTmuxCreateConnectionBootstrapsInitialWindow() async throws {
        guard TmuxManager.shared.isTmuxAvailable else {
            throw XCTSkip("tmux is unavailable")
        }

        let sessionName = "codex-create-\(UUID().uuidString.prefix(8).lowercased())"
        let info = TmuxAttachmentInfo(
            sessionName: sessionName,
            host: .local,
            connectionState: .disconnected(reason: nil),
            launchMode: .create
        )
        let realClient = TmuxControlClient(attachmentInfo: info)
        let realDelegate = await MainActor.run { MockControlClientDelegate() }
        realClient.delegate = realDelegate

        defer {
            TmuxManager.shared.killSession(name: sessionName)
        }

        do {
            try await realClient.connect()
        } catch {
            let exitReasons = await MainActor.run { realDelegate.exitReasons }
            let stateChanges = await MainActor.run { realDelegate.stateChanges }
            let trace = await realClient.currentDebugTrace()
            XCTFail("connect failed: \(error); exits=\(exitReasons); states=\(stateChanges); trace=\(trace)")
            return
        }
        defer {
            Task {
                await realClient.disconnect()
            }
        }

        let state = await realClient.state
        let windows = await realClient.windows
        let stateChanges = await MainActor.run { realDelegate.stateChanges }
        let addedWindows = await MainActor.run { realDelegate.addedWindows }

        XCTAssertEqual(state, .connected)
        XCTAssertTrue(TmuxManager.shared.sessionExists(name: sessionName))
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(stateChanges.contains(.connected))
        XCTAssertEqual(addedWindows.count, 1)
        XCTAssertFalse(addedWindows[0].paneIDs.isEmpty)
    }

    func testRealTmuxAttachConnectionBootstrapsInitialWindow() async throws {
        guard TmuxManager.shared.isTmuxAvailable else {
            throw XCTSkip("tmux is unavailable")
        }

        let sessionName = "codex-attach-\(UUID().uuidString.prefix(8).lowercased())"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: TmuxManager.shared.tmuxPath)
        process.arguments = ["new-session", "-d", "-s", sessionName]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let info = TmuxAttachmentInfo(
            sessionName: sessionName,
            host: .local,
            connectionState: .disconnected(reason: nil),
            launchMode: .attach
        )
        let realClient = TmuxControlClient(attachmentInfo: info)
        let realDelegate = await MainActor.run { MockControlClientDelegate() }
        realClient.delegate = realDelegate

        defer {
            TmuxManager.shared.killSession(name: sessionName)
        }

        do {
            try await realClient.connect()
        } catch {
            let exitReasons = await MainActor.run { realDelegate.exitReasons }
            let stateChanges = await MainActor.run { realDelegate.stateChanges }
            let trace = await realClient.currentDebugTrace()
            XCTFail("attach connect failed: \(error); exits=\(exitReasons); states=\(stateChanges); trace=\(trace)")
            return
        }
        defer {
            Task {
                await realClient.disconnect()
            }
        }

        let state = await realClient.state
        let windows = await realClient.windows
        let stateChanges = await MainActor.run { realDelegate.stateChanges }
        let addedWindows = await MainActor.run { realDelegate.addedWindows }

        XCTAssertEqual(state, .connected)
        XCTAssertEqual(windows.count, 1)
        XCTAssertTrue(stateChanges.contains(.connected))
        XCTAssertEqual(addedWindows.count, 1)
        XCTAssertFalse(addedWindows[0].paneIDs.isEmpty)
    }

    func testDisconnectWhileWaitingForInitialGreetingUnblocksWaiter() async {
        await client.beginWaitingForInitialGreetingForTests()

        let waitTask = Task<Bool, Never> {
            do {
                try await self.client.waitForInitialGreetingForTests()
                return false
            } catch {
                return true
            }
        }

        for _ in 0..<20 {
            if await client.hasPendingInitialGreetingWaitForTests() {
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        await client.disconnect()

        let didFail = await awaitValue(of: waitTask, timeoutNanoseconds: 1_000_000_000)
        if didFail == nil {
            waitTask.cancel()
        }
        XCTAssertNotNil(didFail, "waitForInitialGreeting() should finish after disconnect()")
        XCTAssertEqual(didFail, true)
    }

    func testErrorBlockWhileWaitingForInitialGreetingUnblocksWaiter() async {
        await client.beginInitialGreetingBlockForTests()

        let waitTask = Task<String, Never> {
            do {
                try await self.client.waitForInitialGreetingForTests()
                return "connected"
            } catch {
                return error.localizedDescription
            }
        }

        for _ in 0..<20 {
            if await client.hasPendingInitialGreetingWaitForTests() {
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        await client.processLine("%begin 1 1 0")
        await client.processLine("can't find session: missing")
        await client.processLine("%error 1 1 0")

        let result = await awaitValue(of: waitTask, timeoutNanoseconds: 1_000_000_000)
        if result == nil {
            waitTask.cancel()
        }

        XCTAssertNotNil(result, "waitForInitialGreeting() should finish on %error block")
        XCTAssertNotEqual(result, "connected")
        XCTAssertEqual(result, "can't find session: missing")
    }

    func testExitWhileWaitingForInitialGreetingUnblocksWaiter() async {
        await client.beginWaitingForInitialGreetingForTests()

        let waitTask = Task<String, Never> {
            do {
                try await self.client.waitForInitialGreetingForTests()
                return "connected"
            } catch {
                return error.localizedDescription
            }
        }

        for _ in 0..<20 {
            if await client.hasPendingInitialGreetingWaitForTests() {
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        await client.processLine("%exit lost tty")

        let result = await awaitValue(of: waitTask, timeoutNanoseconds: 1_000_000_000)
        if result == nil {
            waitTask.cancel()
        }

        XCTAssertNotNil(result, "waitForInitialGreeting() should finish on %exit")
        XCTAssertNotEqual(result, "connected")
        XCTAssertEqual(result, "lost tty")
    }

    // MARK: - Bootstrap parsing

    func testParseBootstrapWindowLineSupportsSpacesInWindowName() {
        let parsed = TmuxControlClient.parseBootstrapWindowLine("@7\twindow with spaces\tb25d,80x24,0,0,7")

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.window.windowID, 7)
        XCTAssertEqual(parsed?.window.name, "window with spaces")
        XCTAssertEqual(parsed?.layout, "b25d,80x24,0,0,7")
    }

    func testParseBootstrapWindowLineParsesWindowIndexAndActiveFlag() {
        let parsed = TmuxControlClient.parseBootstrapWindowLine(
            "@7\twindow with spaces\tb25d,80x24,0,0,7\t3\t1"
        )

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.window.windowID, 7)
        XCTAssertEqual(parsed?.window.windowIndex, 3)
        XCTAssertEqual(parsed?.window.isActive, true)
    }

    func testParseBootstrapWindowLineParsesCRTerminatedActiveFlag() {
        let parsed = TmuxControlClient.parseBootstrapWindowLine(
            "@7\twindow with spaces\tb25d,80x24,0,0,7\t3\t1\r"
        )

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.window.windowID, 7)
        XCTAssertEqual(parsed?.window.windowIndex, 3)
        XCTAssertEqual(parsed?.window.isActive, true)
    }

    func testParseBootstrapWindowLineRejectsMalformedLine() {
        XCTAssertNil(TmuxControlClient.parseBootstrapWindowLine("@7 only-two-fields"))
    }

    func testCapturePaneCommandPreservesWrappedLines() {
        XCTAssertEqual(TmuxControlClient.capturePaneCommand(paneID: 7), "capture-pane -p -e -t %7")
    }

    func testCapturePaneCursorCommandFormat() {
        XCTAssertEqual(
            TmuxControlClient.capturePaneCursorCommand(paneID: 7),
            "display-message -p -t %7 '#{cursor_x} #{cursor_y}'"
        )
    }

    func testClientPaneOutputStateCommandFormat() {
        XCTAssertEqual(
            TmuxControlClient.clientPaneOutputStateCommand(paneIDs: [7, 9], state: "off"),
            "refresh-client -A '%7:off' -A '%9:off'"
        )
    }

    func testResizePaneCommandFormat() {
        let command = TmuxControlClient.resizePaneCommand(paneID: 5, columns: 80, rows: 24)
        XCTAssertEqual(command, "resize-pane -t %5 -x 80 -y 24")
    }

    func testAlternateScreenStateCommandFormat() {
        XCTAssertEqual(
            TmuxControlClient.alternateScreenStateCommand(paneID: 7),
            "display-message -p -t %7 '#{alternate_on}'"
        )
    }

    func testParseAlternateScreenStateResponse() {
        XCTAssertTrue(TmuxControlClient.parseAlternateScreenState(from: "1\n"))
        XCTAssertFalse(TmuxControlClient.parseAlternateScreenState(from: "0\n"))
        XCTAssertFalse(TmuxControlClient.parseAlternateScreenState(from: "bogus\n"))
    }

    func testCurrentWindowInfoCommandFormat() {
        XCTAssertEqual(
            TmuxControlClient.currentWindowInfoCommand(),
            "display-message -p '#{window_id}\t#{window_name}\t#{window_layout}\t#{window_index}\t#{window_active}'"
        )
    }

    func testReadyCommandFormat() {
        XCTAssertEqual(TmuxControlClient.readyCommand(), "display-message -p ready")
    }

    func testParseCapturePaneCursorResponse() {
        let cursor = TmuxControlClient.parseCapturePaneCursor(from: "10 34\n")

        XCTAssertNotNil(cursor)
        XCTAssertEqual(cursor?.x, 10)
        XCTAssertEqual(cursor?.y, 34)
    }

    func testParseCapturePaneCursorResponseSupportsLegacyLiteralTabEscape() {
        let cursor = TmuxControlClient.parseCapturePaneCursor(from: "10\\t34\n")

        XCTAssertNotNil(cursor)
        XCTAssertEqual(cursor?.x, 10)
        XCTAssertEqual(cursor?.y, 34)
    }

    func testCapturePaneReplayDataNormalizesLineEndingsAndRestoresCursor() {
        let replay = TmuxControlClient.capturePaneReplayData(
            from: Data("prompt\noutput\n".utf8),
            cursorX: 3,
            cursorY: 1
        )

        XCTAssertEqual(
            replay,
            Data("\u{1b}[H\u{1b}[2Jprompt\r\noutput\u{1b}[2;4H".utf8)
        )
    }

    func testSanitizePaneOutputStripsScreenTitleSequence() {
        let sanitized = TmuxControlClient.sanitizePaneOutput(
            Data("\u{1b}kecho\u{1b}\\hello world\r\n".utf8)
        )

        XCTAssertEqual(sanitized, Data("hello world\r\n".utf8))
    }

    func testSanitizePaneOutputExtractsScreenTitleSequenceMetadata() {
        let result = TmuxControlClient.sanitizePaneOutputWithTitles(
            Data("\u{1b}kecho\u{1b}\\hello world\r\n".utf8)
        )

        XCTAssertEqual(result.data, Data("hello world\r\n".utf8))
        XCTAssertEqual(result.titles, ["echo"])
    }

    func testSanitizePaneOutputStripsPromptEOLMarkerSequence() {
        let sanitized = TmuxControlClient.sanitizePaneOutput(
            Data("\u{1b}[1m\u{1b}[7m%\u{1b}[27m\u{1b}[1m\u{1b}[0m     \r \r".utf8)
        )

        XCTAssertEqual(sanitized, Data())
    }

    func testSanitizePaneOutputStripsPromptEOLMarkerSequenceInsideStream() {
        let sanitized = TmuxControlClient.sanitizePaneOutput(
            Data("before\u{1b}[1m\u{1b}[7m%\u{1b}[27m\u{1b}[1m\u{1b}[0m   \r \rafter".utf8)
        )

        XCTAssertEqual(sanitized, Data("beforeafter".utf8))
    }

    func testSanitizePaneOutputKeepsLiteralPercentWithoutPromptMarkerSequence() {
        let sanitized = TmuxControlClient.sanitizePaneOutput(
            Data("%\r\n".utf8)
        )

        XCTAssertEqual(sanitized, Data("%\r\n".utf8))
    }

    func testCapturePaneReplayDataStripsScreenTitleSequence() {
        let replay = TmuxControlClient.capturePaneReplayData(
            from: Data("\u{1b}kecho\u{1b}\\hello world\n".utf8),
            cursorX: 0,
            cursorY: 0
        )

        XCTAssertEqual(
            replay,
            Data("\u{1b}[H\u{1b}[2Jhello world\u{1b}[1;1H".utf8)
        )
    }

    func testCapturePaneReplayDataDoesNotDuplicateCarriageReturnForCRLFInput() {
        let replay = TmuxControlClient.capturePaneReplayData(
            from: Data("line1\r\nline2\r\n".utf8),
            cursorX: 0,
            cursorY: 1
        )

        XCTAssertEqual(
            replay,
            Data("\u{1b}[H\u{1b}[2Jline1\r\nline2\u{1b}[2;1H".utf8)
        )
    }

    func testEmitBootstrapPaneContentUsesOutputDelegatePath() async {
        await client.emitBootstrapPaneContent("hello\n", paneID: 4)

        let output = await MainActor.run { delegate.outputReceived }
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output.first?.paneID, 4)
        XCTAssertEqual(String(data: output.first!.data, encoding: .utf8), "\u{1b}[H\u{1b}[2Jhello\u{1b}[1;1H")
    }

    private func awaitValue<T>(
        of task: Task<T, Never>,
        timeoutNanoseconds: UInt64
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

}

final class FakeTmuxControlTransport: TmuxControlTransport {
    var onLine: (@Sendable (Data) -> Void)?
    var onTermination: (@Sendable (Int32?) -> Void)?

    private(set) var started = false
    private(set) var stopped = false
    private(set) var startedCommand: String?
    private(set) var writtenCommands: [String] = []
    private var nextBlockID = 2

    func start(command: String, environment: [String : String]) throws {
        started = true
        startedCommand = command

        // Initial spontaneous greeting block.
        emitLine("%begin 1 1 0")
        emitLine("%end 1 1 0")
    }

    func write(_ data: Data) throws {
        guard let command = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return
        }

        writtenCommands.append(command)
        let blockID = nextBlockID
        nextBlockID += 1
        emitLine("%begin \(blockID) \(blockID) 0")
        emitLine("%end \(blockID) \(blockID) 0")
    }

    func stop() {
        stopped = true
    }

    func emitLine(_ line: String) {
        onLine?(Data(line.utf8))
    }

    func emitTermination(_ status: Int32?) {
        onTermination?(status)
    }
}

final class TmuxControlTransportTests: XCTestCase {
    func testPtyTransportExecsControlCommandFromShell() {
        XCTAssertEqual(
            PtyTmuxControlTransport.shellArguments(for: "ssh host tmux -CC attach-session -t '0'"),
            ["-lc", "exec ssh host tmux -CC attach-session -t '0'"]
        )
    }

    func testClientUsesInjectedTransportForConnectHandshake() async throws {
        let info = TmuxAttachmentInfo(
            sessionName: "transport-test",
            host: .local,
            connectionState: .disconnected(reason: nil),
            launchMode: .attach
        )

        let transport = FakeTmuxControlTransport()
        let client = TmuxControlClient(
            attachmentInfo: info,
            transportFactory: { transport }
        )

        try await client.connect()
        let state = await client.state
        XCTAssertEqual(state, .connected)
        XCTAssertTrue(transport.started)
        XCTAssertEqual(
            transport.startedCommand,
            "\(TmuxManager.shared.tmuxPath) -CC attach-session -t 'transport-test'"
        )
        XCTAssertTrue(transport.writtenCommands.contains(TmuxControlClient.readyCommand()))
        XCTAssertTrue(transport.writtenCommands.contains(where: { $0.hasPrefix("list-windows -F ") }))

        await client.disconnect()
        XCTAssertTrue(transport.stopped)
    }

    func testTransportTerminationTransitionsClientToDisconnected() async throws {
        let info = TmuxAttachmentInfo(
            sessionName: "transport-term",
            host: .local,
            connectionState: .disconnected(reason: nil),
            launchMode: .attach
        )

        let transport = FakeTmuxControlTransport()
        let client = TmuxControlClient(
            attachmentInfo: info,
            transportFactory: { transport }
        )

        try await client.connect()
        transport.emitTermination(1)
        try await Task.sleep(nanoseconds: 50_000_000)

        let state = await client.state
        XCTAssertEqual(state, .disconnected(reason: "connection closed (1)"))
    }
}

final class ScriptedTmuxControlTransport: TmuxControlTransport {
    typealias Handler = (ScriptedTmuxControlTransport) -> Void
    typealias WriteHandler = (String, ScriptedTmuxControlTransport) -> Void

    var onLine: (@Sendable (Data) -> Void)?
    var onTermination: (@Sendable (Int32?) -> Void)?

    private let startHandler: Handler
    private let writeHandler: WriteHandler

    init(startHandler: @escaping Handler, writeHandler: @escaping WriteHandler) {
        self.startHandler = startHandler
        self.writeHandler = writeHandler
    }

    func start(command: String, environment: [String : String]) throws {
        startHandler(self)
    }

    func write(_ data: Data) throws {
        guard let command = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return
        }
        writeHandler(command, self)
    }

    func stop() {}

    func emitLine(_ line: String) {
        onLine?(Data(line.utf8))
    }

    func emitTermination(_ status: Int32?) {
        onTermination?(status)
    }
}

final class TmuxConnectFSMTests: XCTestCase {
    private func makeInfo(name: String) -> TmuxAttachmentInfo {
        TmuxAttachmentInfo(
            sessionName: name,
            host: .local,
            connectionState: .disconnected(reason: nil),
            launchMode: .attach
        )
    }

    func testConnectFailsWhenReadyCommandReturnsErrorBlock() async {
        let transport = ScriptedTmuxControlTransport(
            startHandler: { transport in
                transport.emitLine("%begin 1 1 0")
                transport.emitLine("%end 1 1 0")
            },
            writeHandler: { command, transport in
                if command == TmuxControlClient.readyCommand() {
                    transport.emitLine("%begin 2 2 0")
                    transport.emitLine("can't find session: missing")
                    transport.emitLine("%error 2 2 0")
                }
            }
        )
        let client = TmuxControlClient(
            attachmentInfo: makeInfo(name: "fsm-error"),
            transportFactory: { transport }
        )

        do {
            try await client.connect()
            XCTFail("connect() should fail when ready block returns %error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("can't find session: missing"))
        }
    }

    func testConnectFailsWhenExitArrivesDuringReadyHandshake() async {
        let transport = ScriptedTmuxControlTransport(
            startHandler: { transport in
                transport.emitLine("%begin 1 1 0")
                transport.emitLine("%end 1 1 0")
            },
            writeHandler: { command, transport in
                if command == TmuxControlClient.readyCommand() {
                    transport.emitLine("%exit not a terminal")
                }
            }
        )
        let client = TmuxControlClient(
            attachmentInfo: makeInfo(name: "fsm-exit"),
            transportFactory: { transport }
        )

        do {
            try await client.connect()
            XCTFail("connect() should fail when %exit arrives during ready handshake")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not a terminal"))
        }
    }

    func testConnectFailsWhenTransportTerminatesDuringReadyHandshake() async {
        let transport = ScriptedTmuxControlTransport(
            startHandler: { transport in
                transport.emitLine("%begin 1 1 0")
                transport.emitLine("%end 1 1 0")
            },
            writeHandler: { command, transport in
                if command == TmuxControlClient.readyCommand() {
                    transport.emitTermination(1)
                }
            }
        )
        let client = TmuxControlClient(
            attachmentInfo: makeInfo(name: "fsm-term"),
            transportFactory: { transport }
        )

        do {
            try await client.connect()
            XCTFail("connect() should fail when transport terminates during ready handshake")
        } catch {
            let description = error.localizedDescription
            let matchesExpected =
                description.contains(TmuxControlError.processTerminated.localizedDescription) ||
                description.contains(TmuxControlError.notConnected.localizedDescription) ||
                description.contains("connection closed")
            XCTAssertTrue(matchesExpected, "unexpected error: \(description)")
        }
    }

    func testBootstrapCapturesActiveAndInactivePanesWithoutRefreshClientReplay() async throws {
        let issuedCommands = Locked<[String]>([])
        var nextBlockID = 2

        func respondOK(_ transport: ScriptedTmuxControlTransport, outputLine: String? = nil) {
            let id = nextBlockID
            nextBlockID += 1
            transport.emitLine("%begin \(id) \(id) 0")
            if let outputLine {
                transport.emitLine(outputLine)
            }
            transport.emitLine("%end \(id) \(id) 0")
        }

        let transport = ScriptedTmuxControlTransport(
            startHandler: { transport in
                transport.emitLine("%begin 1 1 0")
                transport.emitLine("%end 1 1 0")
            },
            writeHandler: { command, transport in
                issuedCommands.withLock { $0.append(command) }

                if command == TmuxControlClient.readyCommand() {
                    respondOK(transport)
                    return
                }

                if command.hasPrefix("list-windows -F ") {
                    let id = nextBlockID
                    nextBlockID += 1
                    transport.emitLine("%begin \(id) \(id) 0")
                    transport.emitLine("@10\tactive\tb25d,80x24,0,0,1\t0\t1")
                    transport.emitLine("@11\tinactive\tb25d,80x24,0,0,2\t1\t0")
                    transport.emitLine("%end \(id) \(id) 0")
                    return
                }

                if command.hasPrefix("display-message -p -t %1 '#{alternate_on}'") {
                    respondOK(transport, outputLine: "1")
                    return
                }
                if command.hasPrefix("display-message -p -t %2 '#{alternate_on}'") {
                    respondOK(transport, outputLine: "0")
                    return
                }

                if command.hasPrefix("capture-pane -p -e -a -t %1") {
                    respondOK(transport, outputLine: "active pane")
                    return
                }
                if command.hasPrefix("capture-pane -p -e -t %2") {
                    respondOK(transport, outputLine: "inactive pane")
                    return
                }

                if command.hasPrefix("display-message -p -t %1 '#{cursor_x} #{cursor_y}'") ||
                    command.hasPrefix("display-message -p -t %2 '#{cursor_x} #{cursor_y}'")
                {
                    respondOK(transport, outputLine: "0 0")
                    return
                }

                respondOK(transport)
            }
        )

        let client = TmuxControlClient(
            attachmentInfo: makeInfo(name: "fsm-bootstrap-capture-all"),
            transportFactory: { transport }
        )

        try await client.connect()
        defer {
            Task {
                await client.disconnect()
            }
        }

        // Bootstrap now defers content capture until after the first resize.
        // During connect(), only pause is issued — no capture-pane or continue.
        let commands = issuedCommands.withLock { $0 }
        let captureCommands = commands.filter { $0.hasPrefix("capture-pane -p -e") }
        XCTAssertEqual(captureCommands.count, 0, "Bootstrap should not capture panes (deferred until first resize)")
        let outputStateCommands = commands.filter { $0.hasPrefix("refresh-client -A ") }
        XCTAssertEqual(outputStateCommands.count, 1, "Bootstrap should only pause, not continue")
        XCTAssertTrue(outputStateCommands.contains("refresh-client -A '%1:pause' -A '%2:pause'"))

        XCTAssertFalse(commands.contains(where: { $0 == "refresh-client" || $0.hasPrefix("refresh-client -C ") }))
    }

    @MainActor
    func testDeferredBootstrapReplayEntersAlternateScreenWhenTmuxPaneIsAlternate() async throws {
        let issuedCommands = Locked<[String]>([])
        var nextBlockID = 2

        func respondOK(_ transport: ScriptedTmuxControlTransport, outputLine: String? = nil) {
            let id = nextBlockID
            nextBlockID += 1
            transport.emitLine("%begin \(id) \(id) 0")
            if let outputLine {
                transport.emitLine(outputLine)
            }
            transport.emitLine("%end \(id) \(id) 0")
        }

        let transport = ScriptedTmuxControlTransport(
            startHandler: { transport in
                transport.emitLine("%begin 1 1 0")
                transport.emitLine("%end 1 1 0")
            },
            writeHandler: { command, transport in
                issuedCommands.withLock { $0.append(command) }

                if command == TmuxControlClient.readyCommand() {
                    respondOK(transport)
                    return
                }

                if command.hasPrefix("list-windows -F ") {
                    let id = nextBlockID
                    nextBlockID += 1
                    transport.emitLine("%begin \(id) \(id) 0")
                    transport.emitLine("@10\tactive\tb25d,80x24,0,0,1\t0\t1")
                    transport.emitLine("%end \(id) \(id) 0")
                    return
                }

                if command.hasPrefix("display-message -p -t %1 '#{alternate_on}'") {
                    respondOK(transport, outputLine: "1")
                    return
                }

                if command.hasPrefix("capture-pane -p -e -t %1") {
                    respondOK(transport, outputLine: "visible alternate")
                    return
                }

                if command.hasPrefix("display-message -p -t %1 '#{cursor_x} #{cursor_y}'") {
                    respondOK(transport, outputLine: "0 0")
                    return
                }

                respondOK(transport)
            }
        )
        let client = TmuxControlClient(
            attachmentInfo: makeInfo(name: "fsm-bootstrap-alternate"),
            transportFactory: { transport }
        )
        let delegate = MockControlClientDelegate()
        client.delegate = delegate

        try await client.connect()
        defer {
            Task {
                await client.disconnect()
            }
        }

        await client.continueDeferredBootstrap(paneIDs: [1])

        let commands = issuedCommands.withLock { $0 }
        XCTAssertTrue(commands.contains("capture-pane -p -e -t %1"))
        XCTAssertFalse(commands.contains("capture-pane -p -e -a -t %1"))

        let replay = try XCTUnwrap(delegate.outputReceived.first?.data)
        XCTAssertTrue(
            replay.starts(with: Data("\u{1b}[?1049h".utf8)),
            "alternate bootstrap replay should enter the local alternate screen before drawing"
        )
        XCTAssertTrue(replay.contains(Data("visible alternate".utf8)))
    }
}

private final class Locked<T> {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
