import XCTest
@testable import Fantastty

final class PersistenceTests: XCTestCase {

    // MARK: - WorkspaceLayout round-trip with attachment

    func testWorkspaceLayoutWithAttachmentCodable() throws {
        let attachment = TmuxAttachmentInfo(
            sessionName: "dev",
            host: .ssh(SSHHostInfo(user: "me", hostname: "box", port: 2222)),
            connectionState: .disconnected(reason: nil)
        )
        let layout = WorkspaceLayout(
            workspaceID: "test1234",
            baseSessionName: "",
            tabSessionNames: [],
            selectedTabIndex: 0,
            sessionType: .local,
            attachment: attachment
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        XCTAssertEqual(decoded.workspaceID, "test1234")
        XCTAssertEqual(decoded.attachment?.sessionName, "dev")
        XCTAssertEqual(decoded.attachment?.host, .ssh(SSHHostInfo(user: "me", hostname: "box", port: 2222)))
    }

    func testWorkspaceLayoutWithoutAttachmentCodable() throws {
        let layout = WorkspaceLayout(
            workspaceID: "test1234",
            baseSessionName: "fantastty-ws-test1234",
            tabSessionNames: ["fantastty-ws-test1234-tab-1"],
            selectedTabIndex: 1,
            sessionType: .local,
            attachment: nil
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(WorkspaceLayout.self, from: data)
        XCTAssertNil(decoded.attachment)
        XCTAssertEqual(decoded.baseSessionName, "fantastty-ws-test1234")
    }

    func testLayoutSnapshotWithMixedSessionsCodable() throws {
        let snapshot = LayoutSnapshot(
            workspaces: [
                WorkspaceLayout(
                    workspaceID: "managed1",
                    baseSessionName: "fantastty-ws-managed1",
                    tabSessionNames: [],
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: nil
                ),
                WorkspaceLayout(
                    workspaceID: "attached1",
                    baseSessionName: "",
                    tabSessionNames: [],
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: TmuxAttachmentInfo(
                        sessionName: "external",
                        host: .local,
                        connectionState: .disconnected(reason: nil)
                    )
                ),
            ],
            selectedWorkspaceID: "attached1",
            savedAt: Date()
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(LayoutSnapshot.self, from: data)
        XCTAssertEqual(decoded.workspaces.count, 2)
        XCTAssertNil(decoded.workspaces[0].attachment)
        XCTAssertNotNil(decoded.workspaces[1].attachment)
    }

    // MARK: - SSHHostStore

    func testSSHHostStoreAddAndRemove() {
        let store = SSHHostStore(fileURL: tempFileURL())

        let host = SSHHostInfo(user: "me", hostname: "box", port: nil)
        store.add(host)
        XCTAssertEqual(store.hosts.count, 1)
        XCTAssertEqual(store.hosts.first, host)

        // Adding duplicate is no-op
        store.add(host)
        XCTAssertEqual(store.hosts.count, 1)

        store.remove(host)
        XCTAssertEqual(store.hosts.count, 0)
    }

    func testSSHHostStorePersistence() {
        let url = tempFileURL()

        let store1 = SSHHostStore(fileURL: url)
        store1.add(SSHHostInfo(user: nil, hostname: "alpha", port: nil))
        store1.add(SSHHostInfo(user: "root", hostname: "beta", port: 22))

        let store2 = SSHHostStore(fileURL: url)
        XCTAssertEqual(store2.hosts.count, 2)
        XCTAssertEqual(store2.hosts[0].hostname, "alpha")
        XCTAssertEqual(store2.hosts[1].hostname, "beta")
    }

    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("test-ssh-hosts-\(UUID().uuidString).json")
    }
}
