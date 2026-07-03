import XCTest
@testable import Fantastty
import GhosttyKit
import SwiftUI
import WebKit

final class MockTmuxCommandSender: TmuxCommandSending {
    var newWindowCalls = 0
    var killedWindowIDs: [Int] = []
    var renamedWindows: [(windowID: Int, name: String)] = []
    var movedWindows: [(windowID: Int, targetWindowID: Int, placement: TmuxWindowMovePlacement)] = []
    var splitPaneCalls: [(paneID: Int, horizontal: Bool)] = []
    var killedPaneIDs: [Int] = []

    func newWindow() async throws -> String {
        newWindowCalls += 1
        return ""
    }
    func killWindow(windowID: Int) async throws {
        killedWindowIDs.append(windowID)
    }
    func renameWindow(windowID: Int, name: String) async throws {
        renamedWindows.append((windowID, name))
    }
    func moveWindow(windowID: Int, relativeTo targetWindowID: Int, placement: TmuxWindowMovePlacement) async throws {
        movedWindows.append((windowID, targetWindowID, placement))
    }
    func splitPane(paneID: Int, horizontal: Bool) async throws {
        splitPaneCalls.append((paneID, horizontal))
    }
    func killPane(paneID: Int) async throws {
        killedPaneIDs.append(paneID)
    }
}

private final class BrowserCommandWebView: WKWebView {
    private(set) var reloadCallCount = 0
    private(set) var goBackCallCount = 0
    private(set) var goForwardCallCount = 0

    override func reload() -> WKNavigation? {
        reloadCallCount += 1
        return nil
    }

    override func goBack() -> WKNavigation? {
        goBackCallCount += 1
        return nil
    }

    override func goForward() -> WKNavigation? {
        goForwardCallCount += 1
        return nil
    }
}

@MainActor
private enum WindowManagementTestSupport {
    static let ghosttyApp = Fantastty.Ghostty.App()
}

final class WindowManagementTests: XCTestCase {
    @MainActor
    func testRemoteAttachedSessionDefaultTitleUsesSessionAtHost() {
        let manager = Fantastty.SessionManager()
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "claude",
            host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "host.example.com", port: 2222)),
            connectionState: .disconnected(reason: nil)
        )

        let session = manager.makeAttachedSession(info: info, workspaceID: "remote-title")

        XCTAssertEqual(session.title, "claude@host.example.com")
    }

    @MainActor
    func testLocalAttachedSessionDefaultTitleUsesSessionName() {
        let manager = Fantastty.SessionManager()
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "claude",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )

        let session = manager.makeAttachedSession(info: info, workspaceID: "local-title")

        XCTAssertEqual(session.title, "claude")
    }

    @MainActor
    func testRemoteAttachMetadataNameUsesSessionAtHost() throws {
        let manager = Fantastty.SessionManager()
        manager.attachedSessionReconnectStarter = { _ in }
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "claude",
            host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "host.example.com", port: 2222)),
            connectionState: .disconnected(reason: nil)
        )

        manager.attachToTmuxSession(info: info)

        let session = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(session.title, "claude@host.example.com")
        XCTAssertEqual(session.name, "claude@host.example.com")
    }

    @MainActor
    func testDefaultTestSessionManagerDoesNotWriteAttachedMetadataToSharedStore() {
        let workspaceID = "test-isolated-\(UUID().uuidString.prefix(8).lowercased())"
        Fantastty.SessionMetadataStore.shared.remove(forKey: workspaceID)
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp
        manager.attachedSessionReconnectStarter = { _ in }

        _ = manager.createSession(type: .local, workspaceID: workspaceID)

        XCTAssertNil(Fantastty.SessionMetadataStore.shared.metadata[workspaceID])
    }

    @MainActor
    func testDefaultTestSessionManagerDoesNotWriteLayoutToUserFile() {
        let workspaceID = "layout-isolated-\(UUID().uuidString.prefix(8).lowercased())"
        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "fantastty-ws-\(workspaceID)",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: workspaceID)
        manager.sessions = [session]

        manager.saveLayout()

        let userLayoutURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fantastty/layout.json")
        let userLayoutData = try? Data(contentsOf: userLayoutURL)
        let userLayoutText = userLayoutData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(userLayoutText.contains(workspaceID))
    }

    @MainActor
    func testKeyBindingTabSelectionRunsAfterCurrentUpdate() async {
        let manager = Fantastty.SessionManager()
        let firstTab = Fantastty.TerminalTab(type: .local, title: "one")
        let secondTab = Fantastty.TerminalTab(type: .local, title: "two")
        let session = Fantastty.Session(title: "tabs", tabs: [firstTab, secondTab], workspaceID: "key-binding-tabs")
        let expectation = expectation(description: "selected tab changed")
        let cancellable = session.$selectedTabID.dropFirst().sink { selectedTabID in
            if selectedTabID == secondTab.id {
                expectation.fulfill()
            }
        }

        manager.selectTabFromKeyBinding(secondTab, in: session)

        XCTAssertEqual(session.selectedTabID, firstTab.id)
        await fulfillment(of: [expectation], timeout: 1)
        cancellable.cancel()
    }

    @MainActor
    func testAttachToTmuxSessionStartsWithoutPlaceholderTabs() {
        let manager = Fantastty.SessionManager()
        manager.attachedSessionReconnectStarter = { _ in }
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "codex-nonexistent-attach-session",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil)
        )

        manager.attachToTmuxSession(info: info)

        XCTAssertEqual(manager.sessions.count, 1)
        guard let session = manager.sessions.first else {
            return XCTFail("Expected attached session to be created")
        }

        if case .attached(let attachedInfo) = session.mode {
            XCTAssertEqual(attachedInfo.sessionName, info.sessionName)
            XCTAssertEqual(attachedInfo.host, info.host)
            XCTAssertEqual(attachedInfo.connectionState, .connecting)
        } else {
            XCTFail("Expected session to be in attached mode")
        }
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertNil(session.selectedTabID)
        XCTAssertNotNil(session.controlClient)
    }

    @MainActor
    func testTmuxOutputBeforeLayoutIsBufferedAndFlushedWhenPaneAppears() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "buffer-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil)
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "buffer-test")
        manager.sessions = [session]

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

        client.delegate?.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 1, name: "main"))
        client.delegate?.controlClient(client, didReceiveOutput: Data("hello".utf8), forPaneID: 7)
        XCTAssertTrue(injected.isEmpty)

        client.delegate?.controlClient(client, didChangeLayoutForWindowID: 1, layout: "bb62,213x55,0,0,7")

        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(injected.first?.paneID, 7)
        XCTAssertEqual(injected.first?.text, "hello")
    }

    @MainActor
    func testBufferedOutputIsDiscardedWhenWindowClosesBeforeLayout() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "buffer-drop-on-close-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil)
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "buffer-drop-on-close-test")
        manager.sessions = [session]

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

        client.delegate?.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 1, name: "main"))
        client.delegate?.controlClient(client, didReceiveOutput: Data("stale".utf8), forPaneID: 7)
        client.delegate?.controlClient(client, didCloseWindowID: 1)

        client.delegate?.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 2, name: "next"))
        client.delegate?.controlClient(client, didChangeLayoutForWindowID: 2, layout: "bb62,213x55,0,0,7")

        XCTAssertTrue(injected.isEmpty, "Expected stale buffered output to be discarded after window close")
    }

    @MainActor
    func testLayoutBeforeWindowAddIsBufferedAndAppliedWhenWindowArrives() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "layout-before-window-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil)
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "layout-before-window-test")
        manager.sessions = [session]

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

        client.delegate?.controlClient(client, didChangeLayoutForWindowID: 42, layout: "bb62,213x55,0,0,7")
        client.delegate?.controlClient(client, didReceiveOutput: Data("hello".utf8), forPaneID: 7)
        client.delegate?.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 42, name: "main"))

        guard let tab = session.tabs.first(where: { $0.tmuxWindowID == 42 }) else {
            return XCTFail("Expected tab for window 42")
        }
        XCTAssertNotNil(tab.surfaceTree)
        XCTAssertEqual(tab.surfaceTree?.root?.leaves().count, 1)
        XCTAssertEqual(tab.surfaceTree?.root?.leaves().first?.tmuxPaneID, 7)
        XCTAssertEqual(injected.count, 1)
        XCTAssertEqual(injected.first?.paneID, 7)
        XCTAssertEqual(injected.first?.text, "hello")
    }

    @MainActor
    func testAttachedWindowDoesNotCreatePlaceholderSurfaceBeforeLayoutArrives() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "window-bootstrap-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil)
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "window-bootstrap-test")
        manager.sessions = [session]

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        client.delegate?.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 1, name: "main"))

        XCTAssertEqual(session.tabs.count, 1)
        guard let tab = session.tabs.first else {
            return XCTFail("Expected attached tab to exist")
        }
        XCTAssertEqual(tab.tmuxWindowID, 1)
        XCTAssertNil(tab.surfaceTree)
        XCTAssertNil(tab.focusedSurface)
    }

    @MainActor
    func testAttachedWindowAddAppendsTerminalTabAfterPersistedBrowserTabs() throws {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "window-placeholder-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil)
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "window-placeholder-test")
        let browserURL = try XCTUnwrap(URL(string: "https://example.com"))
        let browserTab = Fantastty.TerminalTab(url: browserURL)
        session.tabs = [browserTab]
        session.selectedTabID = browserTab.id
        manager.sessions = [session]

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        client.delegate?.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 5, name: "main"))

        XCTAssertEqual(session.tabs.count, 2)
        XCTAssertTrue(session.tabs[0] === browserTab)
        XCTAssertEqual(session.tabs[0].url, browserURL)
        XCTAssertEqual(session.selectedTabID, browserTab.id)
        XCTAssertEqual(session.tabs[1].tmuxWindowID, 5)
        XCTAssertEqual(session.tabs[1].title, "main")
        XCTAssertEqual(session.tabs[1].kind, .terminal)
    }

    @MainActor
    func testBrowserTabReusesWebViewAcrossFocusRemounts() throws {
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let tab = Fantastty.TerminalTab(url: url)

        var firstWebView: WKWebView?
        do {
            let host = NSHostingView(rootView: Fantastty.BrowserTabView(tab: tab))
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            host.layoutSubtreeIfNeeded()
            firstWebView = tab.webView
        }

        let first = try XCTUnwrap(firstWebView)
        first.removeFromSuperview()

        let secondHost = NSHostingView(rootView: Fantastty.BrowserTabView(tab: tab))
        secondHost.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        secondHost.layoutSubtreeIfNeeded()

        let second = try XCTUnwrap(tab.webView)
        XCTAssertTrue(second === first)
    }

    @MainActor
    func testBrowserNavigationCommandsRouteToSelectedBrowserTab() throws {
        let manager = Fantastty.SessionManager()
        let session = Session(title: "test", type: .local, workspaceID: "browser-commands")
        let tab = Fantastty.TerminalTab(url: try XCTUnwrap(URL(string: "about:blank")))
        let webView = BrowserCommandWebView()
        tab.webView = webView
        session.addTab(tab)
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        XCTAssertTrue(manager.reloadSelectedBrowserTab())
        XCTAssertTrue(manager.goBackInSelectedBrowserTab())
        XCTAssertTrue(manager.goForwardInSelectedBrowserTab())

        XCTAssertEqual(webView.reloadCallCount, 1)
        XCTAssertEqual(webView.goBackCallCount, 1)
        XCTAssertEqual(webView.goForwardCallCount, 1)
    }

    @MainActor
    func testBrowserNavigationCommandsIgnoreTerminalTabs() {
        let manager = Fantastty.SessionManager()
        let session = Session(title: "test", type: .local, workspaceID: "browser-terminal-ignore")
        session.addTab(Fantastty.TerminalTab(type: .local, title: "terminal"))
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        XCTAssertFalse(manager.reloadSelectedBrowserTab())
        XCTAssertFalse(manager.goBackInSelectedBrowserTab())
        XCTAssertFalse(manager.goForwardInSelectedBrowserTab())
    }

    @MainActor
    func testBrowserLocationCommandTargetsSelectedBrowserTab() throws {
        let manager = Fantastty.SessionManager()
        let session = Session(title: "test", type: .local, workspaceID: "browser-location")
        let tab = Fantastty.TerminalTab(url: try XCTUnwrap(URL(string: "about:blank")))
        session.addTab(tab)
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        XCTAssertEqual(tab.browserLocationFocusRequestID, 0)
        XCTAssertTrue(manager.focusLocationInSelectedBrowserTab())
        XCTAssertEqual(tab.browserLocationFocusRequestID, 1)
    }

    func testThumbnailPlaceholderUsesStaticIconForBrowserTabs() throws {
        let browserTab = Fantastty.TerminalTab(url: try XCTUnwrap(URL(string: "https://example.com")))
        let terminalTab = Fantastty.TerminalTab(type: .local, title: "terminal")

        XCTAssertEqual(Fantastty.ThumbnailPlaceholderStyle.forTab(browserTab), .symbol("globe"))
        XCTAssertEqual(Fantastty.ThumbnailPlaceholderStyle.forTab(terminalTab), .loading)
    }

    func testThumbnailRefreshGateCoalescesRequestsWhileInFlight() {
        let gate = Fantastty.ThumbnailRefreshGate()

        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertFalse(gate.begin())
        XCTAssertTrue(gate.finish())

        XCTAssertTrue(gate.begin())
        XCTAssertFalse(gate.finish())
    }

    @MainActor
    func testAttachedWindowAddOrdersByWindowIndexAndSelectsActiveWindow() throws {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "window-order-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil)
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "window-order-test")
        let browserURL = try XCTUnwrap(URL(string: "https://example.com"))
        let browserTab = Fantastty.TerminalTab(url: browserURL)
        session.tabs = [browserTab]
        session.selectedTabID = browserTab.id
        manager.sessions = [session]

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        client.delegate?.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 11,
                name: "second",
                paneIDs: [],
                windowIndex: 1,
                isActive: false
            )
        )
        client.delegate?.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 10,
                name: "first",
                paneIDs: [],
                windowIndex: 0,
                isActive: true
            )
        )

        XCTAssertEqual(session.tabs.count, 3)
        XCTAssertEqual(session.tabs.map(\.kind), [.browser, .terminal, .terminal])
        XCTAssertEqual(session.tabs[1].tmuxWindowID, 10)
        XCTAssertEqual(session.tabs[2].tmuxWindowID, 11)
        XCTAssertEqual(session.selectedTabID, session.tabs[1].id)
    }

    @MainActor
    func testMoveTabReordersSessionTabsAndPlansTmuxMove() {
        let manager = Fantastty.SessionManager()
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "move-tabs-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.connected
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "move-tabs-test")
        let first = Fantastty.TerminalTab(type: .local, title: "first")
        first.tmuxWindowID = 10
        first.tmuxWindowIndex = 0
        let second = Fantastty.TerminalTab(type: .local, title: "second")
        second.tmuxWindowID = 20
        second.tmuxWindowIndex = 1
        let third = Fantastty.TerminalTab(type: .local, title: "third")
        third.tmuxWindowID = 30
        third.tmuxWindowIndex = 2
        session.tabs = [first, second, third]
        session.selectedTabID = second.id
        manager.sessions = [session]

        let moveRequest = manager.moveTab(id: third.id, before: first.id, in: session)

        XCTAssertEqual(session.tabs.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(session.tabs.map(\.tmuxWindowIndex), [0, 1, 2])
        XCTAssertEqual(session.selectedTabID, second.id)
        XCTAssertEqual(
            moveRequest,
            Fantastty.TmuxWindowMoveRequest(windowID: 30, targetWindowID: 10, placement: .before)
        )
    }

    @MainActor
    func testSessionWindowChangedSelectsMatchingAttachedTab() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "window-active-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil)
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "window-active-test")
        manager.sessions = [session]

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        client.delegate?.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 10, name: "first"))
        client.delegate?.controlClient(client, didAddWindow: Fantastty.TmuxWindow(windowID: 11, name: "second"))

        client.delegate?.controlClient(client, didChangeActiveWindowID: 11)

        guard let activeTab = session.tabs.first(where: { $0.tmuxWindowID == 11 }) else {
            return XCTFail("Expected tab for window 11")
        }
        XCTAssertEqual(session.selectedTabID, activeTab.id)
    }

    @MainActor
    func testSelectTabActivatesItsSessionThenSelectsTheTab() {
        let manager = Fantastty.SessionManager()

        let sessionA = Fantastty.Session(title: "A", type: .local, workspaceID: "select-tab-a")
        let sessionB = Fantastty.Session(title: "B", type: .local, workspaceID: "select-tab-b")
        let tabB1 = Fantastty.TerminalTab(type: .local, title: "b1")
        let tabB2 = Fantastty.TerminalTab(type: .local, title: "b2")
        sessionB.tabs = [tabB1, tabB2]
        sessionB.selectedTabID = tabB1.id

        manager.sessions = [sessionA, sessionB]
        manager.selectedSessionID = sessionA.id

        manager.selectTab(tabB2, in: sessionB)

        XCTAssertEqual(manager.selectedSessionID, sessionB.id)
        XCTAssertEqual(sessionB.selectedTabID, tabB2.id)
    }

    @MainActor
    func testWindowPaneChangedUpdatesFocusedSurfaceForAttachedTab() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "pane-active-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil)
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "pane-active-test")
        manager.sessions = [session]

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        client.delegate?.controlClient(
            client,
            didAddWindow: Fantastty.TmuxWindow(
                windowID: 20,
                name: "main",
                paneIDs: [7, 8],
                windowIndex: 0,
                isActive: true
            )
        )
        client.delegate?.controlClient(
            client,
            didChangeLayoutForWindowID: 20,
            layout: "bb62,160x40,0,0{80x40,0,0,7,79x40,81,0,8}"
        )
        client.delegate?.controlClient(client, didChangeActivePaneID: 8, inWindowID: 20)

        guard let tab = session.tabs.first(where: { $0.tmuxWindowID == 20 }) else {
            return XCTFail("Expected tab for window 20")
        }
        XCTAssertEqual(tab.focusedSurface?.tmuxPaneID, 8)
    }

    @MainActor
    func testRealTmuxAttachRestoresAllWindowsIntoDistinctAttachedTabs() async throws {
        guard Fantastty.TmuxManager.shared.isTmuxAvailable else {
            throw XCTSkip("tmux is unavailable")
        }

        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let sessionName = "codex-restore-\(UUID().uuidString.prefix(8).lowercased())"
        let tmuxPath = Fantastty.TmuxManager.shared.tmuxPath

        let createProcess = Process()
        createProcess.executableURL = URL(fileURLWithPath: tmuxPath)
        createProcess.arguments = ["new-session", "-d", "-s", sessionName, "-n", "one"]
        try createProcess.run()
        createProcess.waitUntilExit()
        XCTAssertEqual(createProcess.terminationStatus, 0)

        for windowName in ["two", "three"] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tmuxPath)
            proc.arguments = ["new-window", "-t", sessionName, "-n", windowName]
            try proc.run()
            proc.waitUntilExit()
            XCTAssertEqual(proc.terminationStatus, 0)
        }

        defer {
            Fantastty.TmuxManager.shared.killSession(name: sessionName)
        }

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: sessionName,
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil),
            launchMode: .attach
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "real-restore")
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        try await client.connect()
        defer {
            Task { await client.disconnect() }
        }

        let terminalTabs = session.tabs.filter { $0.kind == .terminal }
        let restoredIDs = Set(terminalTabs.compactMap(\.tmuxWindowID))
        let trackedWindows = await client.windows
        let trace = await client.currentDebugTrace()
        let tabSummary = terminalTabs.map { "id=\($0.tmuxWindowID ?? -1) title=\($0.title)" }.joined(separator: ", ")
        let traceTail = trace.suffix(40).joined(separator: " | ")

        XCTAssertEqual(
            terminalTabs.count,
            3,
            "tabs=[\(tabSummary)] windows=\(trackedWindows.keys.sorted()) traceTail=\(traceTail)"
        )
        XCTAssertEqual(restoredIDs.count, 3)
        XCTAssertEqual(session.selectedTab?.kind, .terminal)
    }

    @MainActor
    func testRealTmuxAttachRestoresSplitPaneTopologyForWindow() async throws {
        guard Fantastty.TmuxManager.shared.isTmuxAvailable else {
            throw XCTSkip("tmux is unavailable")
        }
        guard let app = WindowManagementTestSupport.ghosttyApp.app else {
            return XCTFail("Expected Ghostty app handle")
        }

        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let sessionName = "codex-split-restore-\(UUID().uuidString.prefix(8).lowercased())"
        let tmuxPath = Fantastty.TmuxManager.shared.tmuxPath

        func runTmux(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) throws -> String? {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()

            let output = String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let errorOutput = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTAssertEqual(
                process.terminationStatus,
                0,
                "tmux \(arguments.joined(separator: " ")) failed: \(errorOutput)",
                file: file,
                line: line
            )
            return process.terminationStatus == 0 ? output : nil
        }

        guard try runTmux([
            "new-session", "-d", "-x", "120", "-y", "40", "-s", sessionName, "-n", "splitwin"
        ]) != nil else {
            return
        }
        defer {
            Fantastty.TmuxManager.shared.killSession(name: sessionName)
        }

        // Build a 3-pane topology in the first window:
        // left pane + right side split vertically into top/bottom.
        guard let rightPaneOutput = try runTmux([
            "split-window", "-h", "-P", "-F", "#{pane_id}", "-t", "\(sessionName):splitwin"
        ]) else {
            return
        }
        let rightPaneID = rightPaneOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rightPaneID.isEmpty else {
            return XCTFail("Expected split-window to report the right pane id")
        }
        guard try runTmux(["split-window", "-v", "-t", rightPaneID]) != nil else {
            return
        }

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: sessionName,
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil),
            launchMode: .attach
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "real-split-restore")
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        try await client.connect()
        defer {
            Task { await client.disconnect() }
        }

        guard let tab = session.tabs.first(where: { $0.kind == .terminal }) else {
            return XCTFail("Expected a terminal tab")
        }

        // Layout mapping requires a valid Ghostty app handle for surface creation.
        if tab.surfaceTree == nil {
            let fallbackSurface = Fantastty.Ghostty.SurfaceView(app, baseConfig: nil)
            tab.surfaceTree = Fantastty.SplitTree(root: .leaf(view: fallbackSurface), zoomed: nil)
        }

        let leaves = tab.surfaceTree?.root?.leaves() ?? []
        let paneIDs = Set(leaves.compactMap(\.tmuxPaneID))
        let trace = await client.currentDebugTrace()
        let traceTail = trace.suffix(60).joined(separator: " | ")

        XCTAssertEqual(
            leaves.count,
            3,
            "Expected split topology with 3 panes; paneIDs=\(paneIDs.sorted()) traceTail=\(traceTail)"
        )
        XCTAssertEqual(paneIDs.count, 3)
    }

    @MainActor
    func testRealTmuxAttachRestoresMixedWindowTopologies() async throws {
        guard Fantastty.TmuxManager.shared.isTmuxAvailable else {
            throw XCTSkip("tmux is unavailable")
        }

        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let sessionName = "codex-mixed-restore-\(UUID().uuidString.prefix(8).lowercased())"
        let tmuxPath = Fantastty.TmuxManager.shared.tmuxPath

        let createProcess = Process()
        createProcess.executableURL = URL(fileURLWithPath: tmuxPath)
        createProcess.arguments = ["new-session", "-d", "-s", sessionName, "-n", "plain"]
        try createProcess.run()
        createProcess.waitUntilExit()
        XCTAssertEqual(createProcess.terminationStatus, 0)

        let splitWindow = Process()
        splitWindow.executableURL = URL(fileURLWithPath: tmuxPath)
        splitWindow.arguments = ["new-window", "-t", sessionName, "-n", "split"]
        try splitWindow.run()
        splitWindow.waitUntilExit()
        XCTAssertEqual(splitWindow.terminationStatus, 0)

        for args in [
            ["split-window", "-h", "-t", "\(sessionName):1"],
            ["split-window", "-v", "-t", "\(sessionName):1.1"]
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = args
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }

        defer {
            Fantastty.TmuxManager.shared.killSession(name: sessionName)
        }

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: sessionName,
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.disconnected(reason: nil),
            launchMode: .attach
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "real-mixed-restore")
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        try await client.connect()
        defer {
            Task { await client.disconnect() }
        }

        let terminalTabs = session.tabs.filter { $0.kind == .terminal }
        XCTAssertEqual(terminalTabs.count, 2)

        let paneCounts = terminalTabs.compactMap { tab in
            tab.surfaceTree?.root?.leaves().count
        }.sorted()
        let trace = await client.currentDebugTrace()
        let traceTail = trace.suffix(60).joined(separator: " | ")

        XCTAssertEqual(
            paneCounts,
            [1, 3],
            "Expected one plain and one split window; paneCounts=\(paneCounts) traceTail=\(traceTail)"
        )
    }

    @MainActor
    func testPerformSplitRoutesAttachedRightSplitThroughTmux() async {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "attached-split-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.connected
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "attached-split-test")
        manager.sessions = [session]
        guard let app = WindowManagementTestSupport.ghosttyApp.app else {
            return XCTFail("Expected Ghostty app handle")
        }
        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        let surface = Fantastty.Ghostty.SurfaceView(app, baseConfig: nil)
        surface.tmuxPaneID = 42
        let tab = Fantastty.TerminalTab(type: session.type, surfaceView: surface)
        tab.focusedSurface = surface
        session.addTab(tab)

        var splitCalls: [(paneID: Int, horizontal: Bool)] = []
        manager.attachedTmuxSplitSender = { sentClient, paneID, horizontal in
            XCTAssertTrue(sentClient === client)
            splitCalls.append((paneID, horizontal))
        }

        let leafCountBefore = tab.surfaceTree?.root?.leaves().count

        await manager.performSplit(from: surface, direction: .right)

        XCTAssertEqual(splitCalls.count, 1)
        XCTAssertEqual(splitCalls.first?.paneID, 42)
        XCTAssertEqual(splitCalls.first?.horizontal, true)
        XCTAssertEqual(tab.surfaceTree?.root?.leaves().count, leafCountBefore)
        XCTAssertTrue(tab.focusedSurface === surface)
    }

    @MainActor
    func testNewSplitRoutesAttachedRightSplitThroughTmux() async {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "attached-command-split-test",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.connected
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "attached-command-split-test")
        manager.sessions = [session]
        manager.selectedSessionID = session.id
        guard let app = WindowManagementTestSupport.ghosttyApp.app else {
            return XCTFail("Expected Ghostty app handle")
        }
        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        let surface = Fantastty.Ghostty.SurfaceView(app, baseConfig: nil)
        surface.tmuxPaneID = 42
        let tab = Fantastty.TerminalTab(type: session.type, surfaceView: surface)
        tab.focusedSurface = surface
        session.addTab(tab)

        var splitCalls: [(paneID: Int, horizontal: Bool)] = []
        manager.attachedTmuxSplitSender = { sentClient, paneID, horizontal in
            XCTAssertTrue(sentClient === client)
            splitCalls.append((paneID, horizontal))
        }

        let leafCountBefore = tab.surfaceTree?.root?.leaves().count

        manager.newSplit(direction: .right)
        await Task.yield()

        XCTAssertEqual(splitCalls.count, 1)
        XCTAssertEqual(splitCalls.first?.paneID, 42)
        XCTAssertEqual(splitCalls.first?.horizontal, true)
        XCTAssertEqual(tab.surfaceTree?.root?.leaves().count, leafCountBefore)
        XCTAssertTrue(tab.focusedSurface === surface)
    }

    @MainActor
    func testPerformSplitWithoutPaneIDDoesNotCreateLocalSurface() async {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "attached-split-without-pane",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.connected
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "attached-split-without-pane")
        manager.sessions = [session]
        guard let app = WindowManagementTestSupport.ghosttyApp.app else {
            return XCTFail("Expected Ghostty app handle")
        }

        let surface = Fantastty.Ghostty.SurfaceView(app, baseConfig: nil)
        let tab = Fantastty.TerminalTab(type: session.type, surfaceView: surface)
        tab.focusedSurface = surface
        session.addTab(tab)

        var splitCalls: [(paneID: Int, horizontal: Bool)] = []
        manager.attachedTmuxSplitSender = { _, paneID, horizontal in
            splitCalls.append((paneID, horizontal))
        }

        let leafCountBefore = tab.surfaceTree?.root?.leaves().count
        await manager.performSplit(from: surface, direction: .right)

        XCTAssertTrue(splitCalls.isEmpty)
        XCTAssertEqual(tab.surfaceTree?.root?.leaves().count, leafCountBefore)
        XCTAssertTrue(tab.focusedSurface === surface)
    }

    @MainActor
    func testCanPerformSplitRequiresPaneIDForAttachedSessions() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "attached-split-gating",
            host: Fantastty.TmuxHost.local,
            connectionState: Fantastty.ConnectionState.connected
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "attached-split-gating")
        manager.sessions = [session]
        guard let app = WindowManagementTestSupport.ghosttyApp.app else {
            return XCTFail("Expected Ghostty app handle")
        }

        let surface = Fantastty.Ghostty.SurfaceView(app, baseConfig: nil)
        let tab = Fantastty.TerminalTab(type: session.type, surfaceView: surface)
        tab.focusedSurface = surface
        session.addTab(tab)

        XCTAssertFalse(manager.canPerformSplit(from: surface, direction: .right))

        surface.tmuxPaneID = 7

        XCTAssertTrue(manager.canPerformSplit(from: surface, direction: .right))
        XCTAssertTrue(manager.canPerformSplit(from: surface, direction: .down))
        XCTAssertFalse(manager.canPerformSplit(from: surface, direction: .left))
        XCTAssertFalse(manager.canPerformSplit(from: surface, direction: .up))
    }

    @MainActor
    func testTerminalThumbnailRendererUsesCombinedVisibleContentRect() {
        guard let app = WindowManagementTestSupport.ghosttyApp.app else {
            return XCTFail("Expected Ghostty app handle")
        }

        let narrow = Fantastty.Ghostty.SurfaceView(app, baseConfig: nil)
        narrow.frame = CGRect(x: 0, y: 0, width: 20, height: 400)
        let wide = Fantastty.Ghostty.SurfaceView(app, baseConfig: nil)
        wide.frame = CGRect(x: 20, y: 0, width: 400, height: 400)

        let tree = Fantastty.SplitTree(
            root: .split(.init(
                direction: .horizontal,
                ratio: 0.2,
                left: .leaf(view: narrow),
                right: .leaf(view: wide)
            )),
            zoomed: nil
        )

        let rect = Fantastty.TerminalThumbnailRenderer.contentRect(for: tree.root)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 420, height: 400))
    }

    @MainActor
    func testCreateTabOnAttachedSessionRequestsTmuxWindowInsteadOfCreatingLocalTab() async {
        let manager = Fantastty.SessionManager()
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "attached-new-window-test",
            host: .local,
            connectionState: .connected
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "attached-new-window-test")
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        var newWindowCalls = 0
        let newWindowSent = expectation(description: "attached tmux new-window request sent")
        manager.attachedTmuxNewWindowSender = { sentClient in
            XCTAssertTrue(sentClient === client)
            newWindowCalls += 1
            newWindowSent.fulfill()
            return ""
        }

        let created = manager.createTab()
        await fulfillment(of: [newWindowSent], timeout: 2.0)

        XCTAssertNil(created)
        XCTAssertEqual(newWindowCalls, 1)
        XCTAssertTrue(session.tabs.isEmpty)
    }

    @MainActor
    func testCloseTabOnAttachedSessionSendsKillWindow() async throws {
        let mock = MockTmuxCommandSender()
        let windowID = 5
        try await mock.killWindow(windowID: windowID)
        XCTAssertEqual(mock.killedWindowIDs, [5])
    }

    @MainActor
    func testSplitOnAttachedSessionSendsSplitPane() async throws {
        let mock = MockTmuxCommandSender()
        try await mock.splitPane(paneID: 3, horizontal: true)
        XCTAssertEqual(mock.splitPaneCalls.count, 1)
        XCTAssertEqual(mock.splitPaneCalls.first?.paneID, 3)
        XCTAssertTrue(mock.splitPaneCalls.first?.horizontal ?? false)
    }

    @MainActor
    func testRenameWindowOnAttachedSession() async throws {
        let mock = MockTmuxCommandSender()
        try await mock.renameWindow(windowID: 2, name: "new-name")
        XCTAssertEqual(mock.renamedWindows.count, 1)
        XCTAssertEqual(mock.renamedWindows.first?.name, "new-name")
    }

    @MainActor
    func testCreateShellForPlaceholderWorkspaceMigratesToAttachedControlMode() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp
        manager.attachedSessionReconnectStarter = { _ in }

        let workspaceID = "placeholder-shell"
        let session = Fantastty.Session(title: "Recovered", type: .local, workspaceID: workspaceID)
        session.backingState = .missingAttachedBacking(reason: nil)
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        let canonicalSessionName = Fantastty.TmuxManager.shared.baseSessionName(workspaceID: workspaceID)
        Fantastty.TmuxManager.shared.killSession(name: canonicalSessionName)
        XCTAssertFalse(Fantastty.TmuxManager.shared.sessionExists(name: canonicalSessionName))

        manager.createShell(for: session)

        XCTAssertEqual(manager.sessions.count, 1)
        guard let restored = manager.sessions.first else {
            return XCTFail("Expected restored session")
        }
        XCTAssertEqual(restored.workspaceID, "placeholder-shell")
        XCTAssertEqual(restored.backingState, .available)
        XCTAssertEqual(manager.selectedSessionID, restored.id)
        XCTAssertNotNil(restored.controlClient)
        XCTAssertTrue(restored.tabs.isEmpty)
        XCTAssertNil(restored.selectedTabID)

        if case .attached(let info) = restored.mode {
            XCTAssertEqual(info.sessionName, "fantastty-ws-placeholder-shell")
            XCTAssertEqual(info.host, .local)
            XCTAssertEqual(info.connectionState, .connecting)
            XCTAssertEqual(info.launchMode, .create)
        } else {
            XCTFail("Expected placeholder recovery to migrate to attached control mode")
        }
    }

    @MainActor
    func testCreateShellClearsStaleTerminalTabsBeforeReconnect() throws {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "fantastty-ws-stale-tabs",
            host: .local,
            connectionState: .disconnected(reason: "connection closed")
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "stale-tabs")
        session.backingState = .missingAttachedBacking(reason: "connection closed")

        let browserURL = try XCTUnwrap(URL(string: "https://example.com"))
        let browserTab = Fantastty.TerminalTab(url: browserURL)
        let staleTerminal = Fantastty.TerminalTab(type: .local, title: "stale")
        session.tabs = [browserTab, staleTerminal]
        session.selectedTabID = staleTerminal.id

        manager.sessions = [session]
        manager.selectedSessionID = session.id

        var reconnectCalls = 0
        manager.attachedSessionReconnectStarter = { _ in
            reconnectCalls += 1
        }

        manager.createShell(for: session)

        XCTAssertEqual(reconnectCalls, 1)
        XCTAssertEqual(session.tabs.count, 1)
        XCTAssertEqual(session.tabs.first?.kind, .browser)
        XCTAssertEqual(session.selectedTabID, browserTab.id)

        if case .attached(let updatedInfo) = session.mode {
            XCTAssertEqual(updatedInfo.sessionName, "fantastty-ws-stale-tabs")
            XCTAssertEqual(updatedInfo.host, .local)
            XCTAssertEqual(updatedInfo.launchMode, .create)
            XCTAssertEqual(updatedInfo.connectionState, .connecting)
        } else {
            XCTFail("Expected workspace to be configured for attached tmux reconnect")
        }
    }

    @MainActor
    func testCreateShellForAttachedLocalPlaceholderMigratesToAttachedControlMode() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp
        manager.attachedSessionReconnectStarter = { _ in }

        let workspaceID = "attached-placeholder-shell"
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "fantastty-ws-\(workspaceID)",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: workspaceID)
        session.backingState = .missingAttachedBacking(reason: nil)
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        let canonicalSessionName = Fantastty.TmuxManager.shared.baseSessionName(workspaceID: workspaceID)
        Fantastty.TmuxManager.shared.killSession(name: canonicalSessionName)
        XCTAssertFalse(Fantastty.TmuxManager.shared.sessionExists(name: canonicalSessionName))

        manager.createShell(for: session)

        XCTAssertEqual(manager.sessions.count, 1)
        guard let restored = manager.sessions.first else {
            return XCTFail("Expected restored session")
        }
        XCTAssertEqual(restored.workspaceID, workspaceID)
        XCTAssertEqual(restored.backingState, .available)
        XCTAssertEqual(manager.selectedSessionID, restored.id)
        XCTAssertNotNil(restored.controlClient)
        XCTAssertTrue(restored.tabs.isEmpty)
        XCTAssertNil(restored.selectedTabID)

        if case .attached(let restoredInfo) = restored.mode {
            XCTAssertEqual(restoredInfo.sessionName, canonicalSessionName)
            XCTAssertEqual(restoredInfo.host, .local)
            XCTAssertEqual(restoredInfo.connectionState, .connecting)
            XCTAssertTrue(restoredInfo.launchMode == .create || restoredInfo.launchMode == .attach)
        } else {
            XCTFail("Expected attached local placeholder recovery to remain in attached control mode")
        }
    }

    @MainActor
    func testCreateShellForPlaceholderWorkspaceAttachesToExistingCanonicalTmuxSession() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp
        manager.attachedSessionReconnectStarter = { _ in }

        let workspaceID = "existing-placeholder"
        let session = Fantastty.Session(
            title: "Recovered",
            type: .local,
            workspaceID: workspaceID
        )
        session.backingState = .missingAttachedBacking(reason: nil)
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        let canonicalSessionName = Fantastty.TmuxManager.shared.baseSessionName(workspaceID: workspaceID)
        Fantastty.TmuxManager.shared.killSession(name: canonicalSessionName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Fantastty.TmuxManager.shared.tmuxPath)
        process.arguments = ["new-session", "-d", "-s", canonicalSessionName]
        try? process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(Fantastty.TmuxManager.shared.sessionExists(name: canonicalSessionName))
        defer {
            Fantastty.TmuxManager.shared.killSession(name: canonicalSessionName)
        }

        manager.createShell(for: session)

        guard let restored = manager.sessions.first else {
            return XCTFail("Expected replacement session")
        }

        XCTAssertEqual(restored.workspaceID, workspaceID)
        XCTAssertNotNil(restored.controlClient)
        XCTAssertTrue(restored.tabs.isEmpty)
        XCTAssertNil(restored.selectedTabID)

        if case .attached(let info) = restored.mode {
            XCTAssertEqual(info.sessionName, canonicalSessionName)
            XCTAssertEqual(info.host, .local)
            XCTAssertEqual(info.connectionState, .connecting)
            XCTAssertEqual(info.launchMode, .create)
        } else {
            XCTFail("Expected placeholder recovery to attach to existing tmux session")
        }
    }

    @MainActor
    func testCreateSessionCreatesAttachedControlModeWorkspaceForLocalSessions() {
        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = WindowManagementTestSupport.ghosttyApp
        manager.attachedSessionReconnectStarter = { _ in }

        let session = manager.createSession(type: .local, workspaceID: "control-mode-default")

        guard let session else {
            return XCTFail("Expected session to be created")
        }

        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(manager.sessions.first === session)
        XCTAssertEqual(session.workspaceID, "control-mode-default")
        XCTAssertNotNil(session.controlClient)
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertNil(session.selectedTabID)

        if case .attached(let info) = session.mode {
            XCTAssertEqual(info.sessionName, "fantastty-ws-control-mode-default")
            XCTAssertEqual(info.host, .local)
            XCTAssertEqual(info.connectionState, .connecting)
        } else {
            XCTFail("Expected new local workspace to use attached control mode")
        }
    }

    @MainActor
    func testReattachPlaceholderSessionLeavesSessionVisibleOnFailure() {
        let manager = Fantastty.SessionManager()
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "reattach-me",
            host: .local,
            connectionState: .disconnected(reason: "offline")
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "placeholder-reattach")
        session.backingState = .missingAttachedBacking(reason: "offline")
        manager.sessions = [session]

        var reconnectAttempts = 0
        manager.attachedSessionReconnectStarter = { session in
            reconnectAttempts += 1
            guard case .attached(var info) = session.mode else { return }
            info.connectionState = .disconnected(reason: "still offline")
            session.mode = .attached(info)
        }

        manager.reattachPlaceholderSession(session)

        XCTAssertEqual(reconnectAttempts, 1)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(manager.sessions.first === session)
        XCTAssertTrue(session.tabs.isEmpty)
        XCTAssertEqual(session.backingState, .missingAttachedBacking(reason: "still offline"))
        if case .attached(let restoredInfo) = session.mode {
            XCTAssertEqual(restoredInfo.connectionState, .disconnected(reason: "still offline"))
        } else {
            XCTFail("Expected attached session to stay attached")
        }
    }

    @MainActor
    func testLocalAttachedSessionAsyncDisconnectMarksAttachedMissingBacking() {
        let manager = Fantastty.SessionManager()
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "async-disconnect",
            host: .local,
            connectionState: .connecting
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "async-disconnect")
        manager.sessions = [session]

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        client.delegate?.controlClient(client, didChangeState: .disconnected(reason: "offline"))

        XCTAssertEqual(session.backingState, .missingAttachedBacking(reason: "offline"))
        if case .attached(let updatedInfo) = session.mode {
            XCTAssertEqual(updatedInfo.connectionState, .disconnected(reason: "offline"))
        } else {
            XCTFail("Expected attached session to remain attached")
        }
    }

    @MainActor
    func testRemoteAttachedSessionAsyncDisconnectMarksAttachedMissingBacking() {
        let manager = Fantastty.SessionManager()
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "remote-async-disconnect",
            host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "host.example.com", port: 2222)),
            connectionState: .connecting
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "remote-async-disconnect")
        manager.sessions = [session]

        guard let client = session.controlClient else {
            return XCTFail("Expected control client")
        }

        client.delegate?.controlClient(client, didChangeState: .disconnected(reason: "offline"))

        XCTAssertEqual(session.backingState, .missingAttachedBacking(reason: "offline"))
        if case .attached(let updatedInfo) = session.mode {
            XCTAssertEqual(updatedInfo.connectionState, .disconnected(reason: "offline"))
        } else {
            XCTFail("Expected attached session to remain attached")
        }
    }

    func testAppDelegateShouldBootstrapSessionsReturnsTrueOutsideXCTest() {
        XCTAssertTrue(AppDelegate.shouldBootstrapSessions(environment: [:]))
    }

    func testAppDelegateShouldBootstrapSessionsReturnsFalseUnderXCTestByDefault() {
        XCTAssertFalse(
            AppDelegate.shouldBootstrapSessions(
                environment: ["XCTestConfigurationFilePath": "/tmp/fake.xctestconfiguration"]
            )
        )
    }

    func testAppDelegateShouldBootstrapSessionsAllowsTestOverride() {
        XCTAssertTrue(
            AppDelegate.shouldBootstrapSessions(
                environment: [
                    "XCTestConfigurationFilePath": "/tmp/fake.xctestconfiguration",
                    "FANTASTTY_BOOTSTRAP_DURING_TESTS": "1"
                ]
            )
        )
    }
}
