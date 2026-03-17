import XCTest
@testable import Fantastty
import GhosttyKit

@MainActor
private enum TmuxSessionBridgeTestSupport {
    static let ghosttyApp = Fantastty.Ghostty.App()
}

final class TmuxSessionBridgeTests: XCTestCase {
    func testAttachedTmuxSurfacesUseSilentLocalCommand() {
        XCTAssertEqual(
            TmuxSessionBridge.attachedTmuxSilentCommand,
            "/bin/sh -lc 'stty raw -echo; exec /bin/cat >/dev/null'"
        )
    }

    @MainActor
    func testRegisterAttachedSessionCreatesBinding() {
        let manager = TmuxSessionBridge()
        let session = makeAttachedSession(workspaceID: "v2-bind")

        manager.registerAttachedSession(session)

        XCTAssertTrue(manager.hasBinding(for: "v2-bind"))
    }

    @MainActor
    func testDelegateEventsCreateWindowApplyLayoutAndFlushBufferedOutput() {
        let manager = TmuxSessionBridge()
        manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
        let session = makeAttachedSession(workspaceID: "v2-layout")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        var injected: [(paneID: Int, text: String)] = []
        manager.tmuxOutputInjector = { surface, data in
            guard let paneID = surface.tmuxPaneID,
                  let text = String(data: data, encoding: .utf8) else {
                return false
            }
            injected.append((paneID, text))
            return true
        }

        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 1, name: "main", paneIDs: [], windowIndex: 0, isActive: true))
        manager.controlClient(client, didReceiveOutput: Data("hello".utf8), forPaneID: 7)
        XCTAssertTrue(injected.isEmpty)

        manager.controlClient(client, didChangeLayoutForWindowID: 1, layout: "bb62,213x55,0,0,7")

        guard let tab = session.tabs.first(where: { $0.tmuxWindowID == 1 }) else {
            return XCTFail("Expected tab for tmux window 1")
        }
        XCTAssertEqual(tab.surfaceTree?.root?.leaves().count, 1)
        XCTAssertEqual(tab.surfaceTree?.root?.leaves().first?.tmuxPaneID, 7)
        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(injected.first?.paneID, 7)
        XCTAssertEqual(injected.first?.text, "hello")
    }

    @MainActor
    func testActiveWindowAndPaneEventsTrackSelectionAndFocus() {
        let manager = TmuxSessionBridge()
        manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
        let session = makeAttachedSession(workspaceID: "v2-active")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 1, name: "one", paneIDs: [], windowIndex: 0, isActive: false))
        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 2, name: "two", paneIDs: [], windowIndex: 1, isActive: true))
        manager.controlClient(client, didChangeLayoutForWindowID: 1, layout: "bb62,213x55,0,0,7")
        manager.controlClient(client, didChangeLayoutForWindowID: 2, layout: "bb62,213x55,0,0,9")

        manager.controlClient(client, didChangeActiveWindowID: 2)
        manager.controlClient(client, didChangeActivePaneID: 9, inWindowID: 2)

        guard let selected = session.selectedTab else {
            return XCTFail("Expected selected tab")
        }
        XCTAssertEqual(selected.tmuxWindowID, 2)
        XCTAssertEqual(selected.focusedSurface?.tmuxPaneID, 9)
    }

    @MainActor
    func testLayoutRebindsReusedSurfacesToCurrentControlClient() {
        let manager = TmuxSessionBridge()
        manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
        let session = makeAttachedSession(workspaceID: "v2-rebind")
        guard let app = manager.ghosttyApp?.app else {
            return XCTFail("Expected ghostty app")
        }

        let staleSurface = Ghostty.SurfaceView(app, baseConfig: nil)
        staleSurface.tmuxPaneID = 7
        staleSurface.tmuxControlClient = nil
        let staleTab = TerminalTab(type: .local, surfaceView: staleSurface)
        staleTab.tmuxWindowID = 1
        staleTab.tmuxWindowIndex = 0
        session.tabs = [staleTab]
        session.selectedTabID = staleTab.id

        manager.registerAttachedSession(session)
        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        manager.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 1,
                name: "main",
                paneIDs: [],
                windowIndex: 0,
                isActive: true
            )
        )
        manager.controlClient(client, didChangeLayoutForWindowID: 1, layout: "bb62,213x55,0,0,7")

        guard let reboundSurface = session.tabs.first?.surfaceTree?.root?.leaves().first else {
            return XCTFail("Expected a rebound surface")
        }
        XCTAssertTrue(reboundSurface === staleSurface)
        XCTAssertTrue(reboundSurface.tmuxControlClient === client)
    }

    @MainActor
    func testLayoutReplacesFocusedSurfaceWhenPreviouslyFocusedPaneDisappears() {
        let manager = TmuxSessionBridge()
        manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
        let session = makeAttachedSession(workspaceID: "v2-focus-layout")
        manager.registerAttachedSession(session)
        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        manager.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 1,
                name: "main",
                paneIDs: [],
                windowIndex: 0,
                isActive: true
            )
        )
        manager.controlClient(client, didChangeLayoutForWindowID: 1, layout: "bb62,213x55,0,0,7")
        guard let tab = session.tabs.first(where: { $0.tmuxWindowID == 1 }) else {
            return XCTFail("Expected tab for window")
        }
        XCTAssertEqual(tab.focusedSurface?.tmuxPaneID, 7)

        manager.controlClient(client, didChangeLayoutForWindowID: 1, layout: "bb62,213x55,0,0,9")

        XCTAssertEqual(tab.focusedSurface?.tmuxPaneID, 9)
    }

    @MainActor
    func testUserTabSelectionRoutesToTmuxSelectWindow() async {
        let manager = TmuxSessionBridge()
        manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
        let session = makeAttachedSession(workspaceID: "v2-select-window")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        var selectedWindowIDs: [Int] = []
        manager.tmuxWindowSelector = { sentClient, windowID in
            XCTAssertTrue(sentClient === client)
            selectedWindowIDs.append(windowID)
        }

        manager.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 1,
                name: "one",
                paneIDs: [],
                windowIndex: 0,
                isActive: true
            )
        )
        manager.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 2,
                name: "two",
                paneIDs: [],
                windowIndex: 1,
                isActive: false
            )
        )

        guard let secondTab = session.tabs.first(where: { $0.tmuxWindowID == 2 }) else {
            return XCTFail("Expected second tab")
        }

        session.selectedTabID = secondTab.id
        await Task.yield()

        XCTAssertEqual(selectedWindowIDs, [2])
    }

    @MainActor
    func testTmuxDrivenWindowSelectionDoesNotEchoSelectWindowCommand() async {
        let manager = TmuxSessionBridge()
        manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
        let session = makeAttachedSession(workspaceID: "v2-select-window-echo")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        var selectedWindowIDs: [Int] = []
        manager.tmuxWindowSelector = { _, windowID in
            selectedWindowIDs.append(windowID)
        }

        manager.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 1,
                name: "one",
                paneIDs: [],
                windowIndex: 0,
                isActive: true
            )
        )
        manager.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 2,
                name: "two",
                paneIDs: [],
                windowIndex: 1,
                isActive: false
            )
        )

        manager.controlClient(client, didChangeActiveWindowID: 2)
        await Task.yield()

        XCTAssertTrue(selectedWindowIDs.isEmpty)
    }

    @MainActor
    func testBootstrapWindowAddsDoNotEchoSelectWindowCommand() async {
        let manager = TmuxSessionBridge()
        manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
        let session = makeAttachedSession(workspaceID: "v2-bootstrap-select-window-echo")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        var selectedWindowIDs: [Int] = []
        manager.tmuxWindowSelector = { _, windowID in
            selectedWindowIDs.append(windowID)
        }

        manager.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 10,
                name: "one",
                paneIDs: [],
                windowIndex: 0,
                isActive: false
            )
        )
        manager.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 11,
                name: "two",
                paneIDs: [],
                windowIndex: 1,
                isActive: true
            )
        )

        await Task.yield()
        XCTAssertTrue(selectedWindowIDs.isEmpty)
    }

    @MainActor
    func testDidCloseWindowInvokesWindowClosedCallback() {
        let manager = TmuxSessionBridge()
        let session = makeAttachedSession(workspaceID: "v2-close-callback")
        manager.registerAttachedSession(session)
        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        var callbacks: [(ObjectIdentifier, Int)] = []
        manager.onWindowClosed = { callbackClient, windowID in
            callbacks.append((ObjectIdentifier(callbackClient), windowID))
        }

        manager.controlClient(client, didCloseWindowID: 42)

        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(callbacks.first?.0, ObjectIdentifier(client))
        XCTAssertEqual(callbacks.first?.1, 42)
    }

    @MainActor
    func testControlClientExitInvokesExitCallback() {
        let manager = TmuxSessionBridge()
        let session = makeAttachedSession(workspaceID: "v2-exit-callback")
        manager.registerAttachedSession(session)
        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        var exitedClientIDs: [ObjectIdentifier] = []
        manager.onClientExit = { callbackClient in
            exitedClientIDs.append(ObjectIdentifier(callbackClient))
        }

        manager.controlClientDidExit(client, reason: "test")

        XCTAssertEqual(exitedClientIDs, [ObjectIdentifier(client)])
    }

    // MARK: - Contract Tests

    @MainActor
    func testWindowAddCreatesTabAtCorrectIndexOrder() {
        let manager = TmuxSessionBridge()
        let session = makeAttachedSession(workspaceID: "contract-order")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        // Add 3 windows out of order by windowIndex
        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 30, name: "third", paneIDs: [], windowIndex: 2, isActive: false))
        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 10, name: "first", paneIDs: [], windowIndex: 0, isActive: false))
        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 20, name: "second", paneIDs: [], windowIndex: 1, isActive: false))

        XCTAssertEqual(session.tabs.count, 3)
        let indices = session.tabs.compactMap { $0.tmuxWindowIndex }
        XCTAssertEqual(indices, indices.sorted(), "Tabs should be ordered by tmuxWindowIndex")
        XCTAssertEqual(session.tabs.map { $0.tmuxWindowID }, [10, 20, 30])
    }

    @MainActor
    func testWindowCloseRemovesTabAndSelectsAdjacent() {
        let manager = TmuxSessionBridge()
        let session = makeAttachedSession(workspaceID: "contract-close")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 1, name: "first", paneIDs: [], windowIndex: 0, isActive: false))
        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 2, name: "second", paneIDs: [], windowIndex: 1, isActive: true))

        XCTAssertEqual(session.tabs.count, 2)

        manager.controlClient(client, didCloseWindowID: 2)

        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(session.tabs.first?.tmuxWindowID, 1)
        XCTAssertNotNil(session.selectedTabID, "A tab should be selected after close")
    }

    @MainActor
    func testActiveWindowChangeDoesNotEchoSelectWindow() async {
        let manager = TmuxSessionBridge()
        manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
        let session = makeAttachedSession(workspaceID: "contract-no-echo")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        var selectedWindowIDs: [Int] = []
        manager.tmuxWindowSelector = { _, windowID in
            selectedWindowIDs.append(windowID)
        }

        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 1, name: "one", paneIDs: [], windowIndex: 0, isActive: true))
        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 2, name: "two", paneIDs: [], windowIndex: 1, isActive: false))

        // Tmux-driven active window change should not echo a select-window back
        manager.controlClient(client, didChangeActiveWindowID: 1)
        await Task.yield()

        XCTAssertTrue(selectedWindowIDs.isEmpty, "Tmux-driven window activation should not echo select-window back to tmux")
    }

    @MainActor
    func testClientExitTearsDownAndSetsDisconnected() {
        let manager = TmuxSessionBridge()
        manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
        let session = makeAttachedSession(workspaceID: "contract-exit")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 1, name: "main", paneIDs: [], windowIndex: 0, isActive: true))
        manager.controlClient(client, didChangeLayoutForWindowID: 1, layout: "bb62,213x55,0,0,7")

        manager.controlClientDidExit(client, reason: "connection lost")

        guard case .attached(let info) = session.mode else {
            return XCTFail("Expected session to remain in attached mode")
        }
        guard case .disconnected(let reason) = info.connectionState else {
            return XCTFail("Expected disconnected state after client exit")
        }
        XCTAssertEqual(reason, "connection lost")
    }

    @MainActor
    func testWindowRenamedUpdatesTabTitle() {
        let manager = TmuxSessionBridge()
        let session = makeAttachedSession(workspaceID: "contract-rename")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 5, name: "original", paneIDs: [], windowIndex: 0, isActive: true))

        guard let tab = session.tabs.first(where: { $0.tmuxWindowID == 5 }) else {
            return XCTFail("Expected tab for window 5")
        }
        XCTAssertEqual(tab.title, "original")

        manager.controlClient(client, didRenameWindowID: 5, to: "renamed")

        XCTAssertEqual(tab.title, "renamed", "Tab title should update after window rename event")
    }

    @MainActor
    func testOutputBeforeWindowAddIsBufferedAndFlushed() {
        let manager = TmuxSessionBridge()
        manager.ghosttyApp = TmuxSessionBridgeTestSupport.ghosttyApp
        let session = makeAttachedSession(workspaceID: "contract-buffer")
        manager.registerAttachedSession(session)

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        var injected: [(paneID: Int, text: String)] = []
        manager.tmuxOutputInjector = { surface, data in
            guard let paneID = surface.tmuxPaneID,
                  let text = String(data: data, encoding: .utf8) else {
                return false
            }
            injected.append((paneID, text))
            return true
        }

        // Send output before window-add — should not be delivered yet
        manager.controlClient(client, didReceiveOutput: Data("buffered".utf8), forPaneID: 42)
        XCTAssertTrue(injected.isEmpty, "Output should be buffered before the window and layout are established")

        // Add window and apply layout containing pane 42
        manager.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 7, name: "win", paneIDs: [], windowIndex: 0, isActive: true))
        manager.controlClient(client, didChangeLayoutForWindowID: 7, layout: "bb62,213x55,0,0,42")

        XCTAssertEqual(injected.count, 1, "Buffered output should be flushed after layout is applied")
        XCTAssertEqual(injected.first?.paneID, 42)
        XCTAssertEqual(injected.first?.text, "buffered")
    }
}

@MainActor
private extension TmuxSessionBridgeTests {
    func makeAttachedSession(workspaceID: String) -> Session {
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "tmux-\(workspaceID)",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )
        let session = Session(title: "Workspace \(workspaceID)", type: .local, workspaceID: workspaceID)
        session.mode = .attached(info)
        session.controlClient = Fantastty.TmuxControlClient(attachmentInfo: info)
        return session
    }
}
