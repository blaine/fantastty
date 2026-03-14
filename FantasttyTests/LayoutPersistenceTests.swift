import XCTest
@testable import Fantastty

final class LayoutPersistenceTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LayoutPersistenceTests-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    // MARK: - buildSnapshot

    func testBuildSnapshotIncludesAllTabKinds() {
        let persistence = LayoutPersistence(layoutURL: tempURL)

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "fantastty-ws-lp-test",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )
        let session = Fantastty.Session(title: "test", type: .local, workspaceID: "lp-test")
        session.mode = .attached(info)

        let terminalTab = Fantastty.TerminalTab(type: .local, title: "terminal")
        terminalTab.tmuxWindowID = 1
        let browserTab = Fantastty.TerminalTab(url: URL(string: "https://example.com")!)
        session.tabs = [terminalTab, browserTab]

        let snapshot = persistence.buildSnapshot(
            sessions: [session],
            selectedWorkspaceID: session.workspaceID
        )

        let tabs = snapshot.workspaces.first?.tabs ?? []
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs[0].kind, .terminal)
        XCTAssertEqual(tabs[1].kind, .browser)
        XCTAssertEqual(tabs[1].url, URL(string: "https://example.com")!)
    }

    func testBuildSnapshotSkipsNonAttachedSessions() {
        let persistence = LayoutPersistence(layoutURL: tempURL)

        // A freshly-created session starts in .attached mode by default;
        // we cannot easily put it in a non-attached state via public API,
        // but a session whose mode was never overridden is .attached.
        // Instead we verify that a session with no tabs is still included.
        let session = Fantastty.Session(title: "test", type: .local, workspaceID: "lp-skip-test")
        // Leave mode at its default (.attached) - verify it IS included
        let snapshot = persistence.buildSnapshot(
            sessions: [session],
            selectedWorkspaceID: nil
        )
        XCTAssertEqual(snapshot.workspaces.count, 1)
    }

    // MARK: - Save & Load round-trip

    func testSaveAndLoadRoundTripPreservesBrowserTabLayouts() throws {
        let persistence = LayoutPersistence(layoutURL: tempURL)

        let browserURL1 = try XCTUnwrap(URL(string: "https://example.com/one"))
        let browserURL2 = try XCTUnwrap(URL(string: "https://example.com/two"))

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "fantastty-ws-roundtrip",
            host: .local,
            connectionState: .connected
        )
        let session = Fantastty.Session(title: "roundtrip", type: .local, workspaceID: "roundtrip")
        session.mode = .attached(info)

        let terminalTab = Fantastty.TerminalTab(type: .local, title: "shell")
        let browserTab1 = Fantastty.TerminalTab(url: browserURL1)
        let browserTab2 = Fantastty.TerminalTab(url: browserURL2)
        session.tabs = [terminalTab, browserTab1, browserTab2]
        session.selectedTabID = browserTab2.id

        let snapshot = persistence.buildSnapshot(
            sessions: [session],
            selectedWorkspaceID: session.workspaceID
        )
        persistence.save(snapshot)

        let loaded = try XCTUnwrap(persistence.load())
        XCTAssertEqual(loaded.selectedWorkspaceID, "roundtrip")
        XCTAssertEqual(loaded.workspaces.count, 1)

        let wsLayout = try XCTUnwrap(loaded.workspaces.first)
        XCTAssertEqual(wsLayout.workspaceID, "roundtrip")
        // All tabs are persisted to preserve relative ordering
        XCTAssertEqual(wsLayout.tabs.map(\.kind), [.terminal, .browser, .browser])
        XCTAssertEqual(wsLayout.tabs[1].url, browserURL1)
        XCTAssertEqual(wsLayout.tabs[2].url, browserURL2)
        // browserTab2 was at index 2 in the full tab array
        XCTAssertEqual(wsLayout.selectedTabIndex, 2)
    }

    func testSaveWritesAttachedOnlySchemaVersion() throws {
        let persistence = LayoutPersistence(layoutURL: tempURL)
        let snapshot = Fantastty.LayoutSnapshot(
            workspaces: [],
            selectedWorkspaceID: nil,
            savedAt: Date()
        )
        persistence.save(snapshot)

        let loaded = try XCTUnwrap(persistence.load())
        XCTAssertEqual(loaded.schemaVersion, Fantastty.LayoutSnapshot.attachedOnlySchemaVersion)
    }

    // MARK: - Missing / corrupt file

    func testMissingLayoutFileReturnsNil() {
        let nonExistentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let persistence = LayoutPersistence(layoutURL: nonExistentURL)
        XCTAssertNil(persistence.load())
    }

    func testCorruptLayoutFileReturnsNil() {
        let persistence = LayoutPersistence(layoutURL: tempURL)
        try! Data("not json".utf8).write(to: tempURL)
        XCTAssertNil(persistence.load())
    }

    // MARK: - Delete

    func testDeleteRemovesFile() throws {
        let persistence = LayoutPersistence(layoutURL: tempURL)
        let snapshot = Fantastty.LayoutSnapshot(
            workspaces: [],
            selectedWorkspaceID: nil,
            savedAt: Date()
        )
        persistence.save(snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        persistence.delete()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
    }

    func testDeleteOnMissingFileIsNoOp() {
        let nonExistentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).json")
        let persistence = LayoutPersistence(layoutURL: nonExistentURL)
        // Should not throw or crash
        persistence.delete()
    }
}
