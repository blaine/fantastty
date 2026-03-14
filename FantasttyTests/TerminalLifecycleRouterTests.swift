import XCTest
@testable import Fantastty

// MARK: - Local mock (avoids module-ambiguity from TmuxControlClient.swift compiled into both targets)

private final class RouterMockSender: Fantastty.TmuxCommandSending {
    var newWindowCalls = 0
    var killedWindowIDs: [Int] = []
    var splitPaneCalls: [(paneID: Int, horizontal: Bool)] = []
    var killedPaneIDs: [Int] = []

    func newWindow() async throws -> String {
        newWindowCalls += 1
        return ""
    }
    func killWindow(windowID: Int) async throws {
        killedWindowIDs.append(windowID)
    }
    func renameWindow(windowID: Int, name: String) async throws {}
    func splitPane(paneID: Int, horizontal: Bool) async throws {
        splitPaneCalls.append((paneID, horizontal))
    }
    func killPane(paneID: Int) async throws {
        killedPaneIDs.append(paneID)
    }
}

final class TerminalLifecycleRouterTests: XCTestCase {

    // MARK: - Helpers

    @MainActor
    private func makeSession(workspaceID: String = "router-test") -> (Session, RouterMockSender) {
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "tmux-\(workspaceID)",
            host: .local,
            connectionState: .connected
        )
        let session = Session(title: "Test", type: .local, workspaceID: workspaceID)
        session.mode = .attached(info)

        let sender = RouterMockSender()
        return (session, sender)
    }

    @MainActor
    private func makeTerminalTab(tmuxWindowID: Int, paneIDs: [Int] = []) -> TerminalTab {
        let tab = TerminalTab(type: .local, title: "tab-\(tmuxWindowID)")
        tab.tmuxWindowID = tmuxWindowID
        return tab
    }

    // MARK: - Close Tab Contracts

    @MainActor
    func testCloseTerminalTabSendsKillWindow() async {
        let (session, sender) = makeSession()
        let tab = makeTerminalTab(tmuxWindowID: 1)
        session.tabs = [tab]
        session.selectedTabID = tab.id

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.closeTerminalTab(tab, in: session)

        XCTAssertEqual(sender.killedWindowIDs, [1])
    }

    @MainActor
    func testClosePaneSendsKillPane() async {
        let (session, sender) = makeSession()
        let tab = makeTerminalTab(tmuxWindowID: 1)
        session.tabs = [tab]

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.closePane(paneID: 7, in: session)

        XCTAssertEqual(sender.killedPaneIDs, [7])
    }

    @MainActor
    func testCloseLastTerminalTabSendsKillWindowButDoesNotKillSession() async {
        let (session, sender) = makeSession()
        let tab = makeTerminalTab(tmuxWindowID: 1)
        session.tabs = [tab]
        session.selectedTabID = tab.id

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.closeTerminalTab(tab, in: session)

        XCTAssertEqual(sender.killedWindowIDs, [1])
    }

    @MainActor
    func testNewTabSendsNewWindow() async {
        let (session, sender) = makeSession()

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.requestNewTab(in: session)

        XCTAssertEqual(sender.newWindowCalls, 1)
    }

    @MainActor
    func testSplitSendsSplitPane() async {
        let (session, sender) = makeSession()

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.requestSplit(paneID: 7, horizontal: true, in: session)

        XCTAssertEqual(sender.splitPaneCalls.count, 1)
        XCTAssertEqual(sender.splitPaneCalls[0].paneID, 7)
        XCTAssertTrue(sender.splitPaneCalls[0].horizontal)
    }

    @MainActor
    func testActionsNoOpWhenDisconnected() async {
        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "tmux-disconnected",
            host: .local,
            connectionState: .disconnected(reason: "gone")
        )
        let session = Session(title: "Test", type: .local, workspaceID: "router-disconnected")
        session.mode = .attached(info)
        let sender = RouterMockSender()

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.requestNewTab(in: session)

        XCTAssertEqual(sender.newWindowCalls, 0)
    }

    @MainActor
    func testCloseBrowserTabSendsNoTmuxCommand() async {
        let (session, sender) = makeSession()
        let browserTab = TerminalTab(url: URL(string: "https://example.com")!)
        session.tabs = [browserTab]

        let router = TerminalLifecycleRouter(commandSender: sender)
        await router.closeTerminalTab(browserTab, in: session)

        XCTAssertTrue(sender.killedWindowIDs.isEmpty)
    }
}
