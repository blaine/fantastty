import XCTest
@testable import Fantastty

final class PersistenceTests: XCTestCase {
    private var workspaceIDsToCleanup: [String] = []

    override func tearDown() {
        for workspaceID in workspaceIDsToCleanup {
            SessionMetadataStore.shared.remove(forKey: workspaceID)
        }
        workspaceIDsToCleanup.removeAll()
        super.tearDown()
        Fantastty.SessionManager.layoutURLOverride = nil
    }

    // MARK: - WorkspaceLayout round-trip with attachment

    func testWorkspaceLayoutWithAttachmentCodable() throws {
        let attachment = Fantastty.TmuxAttachmentInfo(
            sessionName: "dev",
            host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box", port: 2222)),
            connectionState: .disconnected(reason: nil)
        )
        let layout = Fantastty.WorkspaceLayout(
            workspaceID: "test1234",
            selectedTabIndex: 0,
            sessionType: .local,
            attachment: attachment
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(Fantastty.WorkspaceLayout.self, from: data)
        XCTAssertEqual(decoded.workspaceID, "test1234")
        XCTAssertEqual(decoded.attachment?.sessionName, "dev")
        XCTAssertEqual(decoded.attachment?.host, Fantastty.TmuxHost.ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box", port: 2222)))
    }

    func testWorkspaceLayoutWithBrowserTabsCodable() throws {
        let browserURL = try XCTUnwrap(URL(string: "https://example.com/docs"))
        let layout = Fantastty.WorkspaceLayout(
            workspaceID: "test1234",
            selectedTabIndex: 1,
            sessionType: .local,
            attachment: nil,
            tabs: [
                Fantastty.WorkspaceTabLayout(kind: .terminal),
                Fantastty.WorkspaceTabLayout(kind: .browser, url: browserURL),
            ]
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(Fantastty.WorkspaceLayout.self, from: data)
        XCTAssertEqual(decoded.workspaceID, "test1234")
        XCTAssertEqual(decoded.tabs.count, 2)
        XCTAssertEqual(decoded.tabs[0].kind, .terminal)
        XCTAssertEqual(decoded.tabs[1].kind, .browser)
        XCTAssertEqual(decoded.tabs[1].url, browserURL)
    }

    func testWorkspaceLayoutWithoutAttachmentCodable() throws {
        let layout = Fantastty.WorkspaceLayout(
            workspaceID: "test1234",
            selectedTabIndex: 1,
            sessionType: .local,
            attachment: nil
        )
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(Fantastty.WorkspaceLayout.self, from: data)
        XCTAssertNil(decoded.attachment)
        XCTAssertEqual(decoded.tabs, [])
    }

    func testSessionMetadataWithAttachmentCodable() throws {
        let metadata = Fantastty.SessionMetadata(
            workspaceID: "remote1234",
            name: "Remote",
            attachment: Fantastty.TmuxAttachmentInfo(
                sessionName: "tmux-remote1234",
                host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box.example.com", port: 2222)),
                connectionState: .disconnected(reason: nil)
            )
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(Fantastty.SessionMetadata.self, from: data)

        XCTAssertEqual(
            decoded.attachment,
            Fantastty.TmuxAttachmentInfo(
                sessionName: "tmux-remote1234",
                host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box.example.com", port: 2222)),
                connectionState: .disconnected(reason: nil)
            )
        )
    }

    func testLayoutSnapshotWithMixedSessionsCodable() throws {
        let snapshot = Fantastty.LayoutSnapshot(
            workspaces: [
                Fantastty.WorkspaceLayout(
                    workspaceID: "local1",
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: nil
                ),
                Fantastty.WorkspaceLayout(
                    workspaceID: "attached1",
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: Fantastty.TmuxAttachmentInfo(
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
        let decoded = try JSONDecoder().decode(Fantastty.LayoutSnapshot.self, from: data)
        XCTAssertEqual(decoded.workspaces.count, 2)
        XCTAssertNil(decoded.workspaces[0].attachment)
        XCTAssertNotNil(decoded.workspaces[1].attachment)
    }

    func testSessionMetadataWithTrashStateCodable() throws {
        let trashedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = Fantastty.SessionMetadata(
            workspaceID: "trashed123",
            name: "Old Workspace",
            isArchived: false,
            isTrashed: true,
            trashedAt: trashedAt
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(Fantastty.SessionMetadata.self, from: data)

        XCTAssertEqual(decoded.workspaceID, "trashed123")
        XCTAssertTrue(decoded.isTrashed)
        XCTAssertEqual(decoded.trashedAt, trashedAt)
        XCTAssertFalse(decoded.isArchived)
    }

    @MainActor
    func testCloseSessionMovesWorkspaceToTrash() {
        let workspaceID = "trash-close-\(UUID().uuidString.prefix(8).lowercased())"
        workspaceIDsToCleanup.append(workspaceID)

        let manager = Fantastty.SessionManager()
        let session = Fantastty.Session(title: "Close Me", type: .local, workspaceID: workspaceID)
        let survivor = Fantastty.Session(title: "Keep Me", type: .local, workspaceID: "survivor")
        manager.sessions = [session, survivor]
        manager.selectedSessionID = session.id

        manager.closeSession(id: session.id, killTmux: false)

        XCTAssertEqual(manager.sessions.map(\.workspaceID), ["survivor"])
        let metadata = SessionMetadataStore.shared.getOrCreate(forKey: workspaceID)
        XCTAssertTrue(metadata.isTrashed)
        XCTAssertNotNil(metadata.trashedAt)
        XCTAssertFalse(metadata.isArchived)
    }

    @MainActor
    func testSaveLayoutPersistsAttachedSessions() throws {
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true

        let localInfo = Fantastty.TmuxAttachmentInfo(
            sessionName: "local-dev",
            host: .local,
            connectionState: .connected
        )
        let remoteInfo = Fantastty.TmuxAttachmentInfo(
            sessionName: "remote-dev",
            host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box", port: 2222)),
            connectionState: .connected
        )

        let localSession = manager.makeAttachedSession(info: localInfo, workspaceID: "local123")
        localSession.selectedTabID = nil
        let remoteSession = manager.makeAttachedSession(info: remoteInfo, workspaceID: "remote123")
        remoteSession.selectedTabID = nil

        manager.sessions = [localSession, remoteSession]
        manager.selectedSessionID = remoteSession.id

        manager.saveLayout()

        let data = try Data(contentsOf: layoutURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Fantastty.LayoutSnapshot.self, from: data)

        XCTAssertEqual(snapshot.workspaces.count, 2)
        XCTAssertEqual(snapshot.selectedWorkspaceID, "remote123")

        let localLayout = try XCTUnwrap(snapshot.workspaces.first { $0.workspaceID == "local123" })
        XCTAssertEqual(localLayout.attachment?.sessionName, "local-dev")
        XCTAssertEqual(localLayout.attachment?.host, .local)
        XCTAssertEqual(localLayout.attachment?.connectionState, .disconnected(reason: nil))

        let remoteLayout = try XCTUnwrap(snapshot.workspaces.first { $0.workspaceID == "remote123" })
        XCTAssertEqual(remoteLayout.attachment?.sessionName, "remote-dev")
        XCTAssertEqual(remoteLayout.attachment?.host, Fantastty.TmuxHost.ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box", port: 2222)))
        XCTAssertEqual(remoteLayout.attachment?.connectionState, .disconnected(reason: nil))
    }

    @MainActor
    func testSaveLayoutWritesAttachedOnlySchemaVersion() throws {
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.attachedSessionReconnectStarter = { _ in }
        _ = manager.createSession(type: .local, workspaceID: "schema-version-test")

        manager.saveLayout()

        let data = try Data(contentsOf: layoutURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Fantastty.LayoutSnapshot.self, from: data)

        XCTAssertEqual(snapshot.schemaVersion, Fantastty.LayoutSnapshot.attachedOnlySchemaVersion)
    }

    func testLayoutSnapshotWithoutSchemaVersionDecodesAsLegacyVersion() throws {
        let legacyJSON = """
        {
          "savedAt": "2026-03-09T12:00:00Z",
          "selectedWorkspaceID": "legacy1234",
          "workspaces": [
            {
              "workspaceID": "legacy1234",
              "baseSessionName": "fantastty-ws-legacy1234",
              "tabSessionNames": [],
              "selectedTabIndex": 0
            }
          ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Fantastty.LayoutSnapshot.self, from: legacyJSON)

        XCTAssertEqual(snapshot.schemaVersion, 0)
    }

    @MainActor
    func testSaveLayoutPersistsBrowserTabsInMixedOrder() throws {
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true

        let info = Fantastty.TmuxAttachmentInfo(
            sessionName: "mixed-browser-dev",
            host: .local,
            connectionState: .connected
        )
        let session = manager.makeAttachedSession(info: info, workspaceID: "mixed-browser-workspace")

        let terminalTab = Fantastty.TerminalTab(type: .local, title: "shell")
        let browserURL1 = try XCTUnwrap(URL(string: "https://example.com/one"))
        let browserURL2 = try XCTUnwrap(URL(string: "https://example.com/two"))
        let browserTab1 = Fantastty.TerminalTab(url: browserURL1)
        let browserTab2 = Fantastty.TerminalTab(url: browserURL2)

        session.tabs = [terminalTab, browserTab1, browserTab2]
        session.selectedTabID = browserTab2.id
        manager.sessions = [session]
        manager.selectedSessionID = session.id

        manager.saveLayout()

        let data = try Data(contentsOf: layoutURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Fantastty.LayoutSnapshot.self, from: data)
        let savedWorkspace = try XCTUnwrap(snapshot.workspaces.first { $0.workspaceID == "mixed-browser-workspace" })

        XCTAssertEqual(savedWorkspace.tabs.map(\.kind), [.browser, .browser])
        XCTAssertEqual(savedWorkspace.tabs[0].url, browserURL1)
        XCTAssertEqual(savedWorkspace.tabs[1].url, browserURL2)
        XCTAssertEqual(savedWorkspace.selectedTabIndex, 1)
    }

    @MainActor
    func testNewLocalControlModeWorkspaceSavesAndRestoresAsAttachedSession() throws {
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL

        let creator = Fantastty.SessionManager()
        creator.ghosttyApp = Fantastty.Ghostty.App()
        creator.persistentSessionsEnabled = true
        creator.attachedSessionReconnectStarter = { _ in }

        let created = try XCTUnwrap(
            creator.createSession(type: .local, workspaceID: "persisted-control-mode")
        )
        creator.saveLayout()

        let data = try Data(contentsOf: layoutURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Fantastty.LayoutSnapshot.self, from: data)
        let savedWorkspace = try XCTUnwrap(
            snapshot.workspaces.first { $0.workspaceID == "persisted-control-mode" }
        )

        XCTAssertEqual(savedWorkspace.attachment?.sessionName, "fantastty-ws-persisted-control-mode")
        XCTAssertEqual(savedWorkspace.attachment?.launchMode, .attach)

        let restorer = Fantastty.SessionManager()
        restorer.persistentSessionsEnabled = true
        restorer.tmuxAvailabilityProvider = { true }
        restorer.liveTmuxWorkspaceProvider = { [:] }
        restorer.workspaceMetadataProvider = { [] }

        var reconnects: [String] = []
        restorer.attachedSessionReconnectStarter = { session in
            guard case .attached(let info) = session.mode else { return }
            reconnects.append(info.sessionName)
        }

        XCTAssertTrue(restorer.restoreTmuxSessions())
        XCTAssertEqual(reconnects, ["fantastty-ws-persisted-control-mode"])
        XCTAssertEqual(restorer.sessions.count, 1)

        let restored = try XCTUnwrap(restorer.sessions.first)
        XCTAssertEqual(restored.workspaceID, created.workspaceID)
        if case .attached(let info) = restored.mode {
            XCTAssertEqual(info.sessionName, "fantastty-ws-persisted-control-mode")
            XCTAssertEqual(info.connectionState, .connecting)
            XCTAssertEqual(info.launchMode, .attach)
        } else {
            XCTFail("Expected restored workspace to stay attached")
        }
    }

    @MainActor
    func testRestoreTmuxSessionsRecreatesAttachedSessionsAndStartsReconnect() throws {
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL
        let localWorkspaceID = "local-\(UUID().uuidString.prefix(8).lowercased())"
        let remoteWorkspaceID = "remote-\(UUID().uuidString.prefix(8).lowercased())"
        workspaceIDsToCleanup.append(localWorkspaceID)
        workspaceIDsToCleanup.append(remoteWorkspaceID)

        let snapshot = Fantastty.LayoutSnapshot(
            workspaces: [
                Fantastty.WorkspaceLayout(
                    workspaceID: localWorkspaceID,
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: Fantastty.TmuxAttachmentInfo(
                        sessionName: "local-dev",
                        host: .local,
                        connectionState: .disconnected(reason: nil)
                    )
                ),
                Fantastty.WorkspaceLayout(
                    workspaceID: remoteWorkspaceID,
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: Fantastty.TmuxAttachmentInfo(
                        sessionName: "remote-dev",
                        host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box", port: 2222)),
                        connectionState: .disconnected(reason: nil)
                    )
                ),
            ],
            selectedWorkspaceID: remoteWorkspaceID,
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: layoutURL)

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = {
            [
                Fantastty.SessionMetadata(workspaceID: localWorkspaceID, name: "Local"),
                Fantastty.SessionMetadata(workspaceID: remoteWorkspaceID, name: "Remote"),
            ]
        }

        var reconnectAttempts: [String] = []
        manager.attachedSessionReconnectStarter = { (session: Fantastty.Session) in
            guard case .attached(let info) = session.mode else {
                return XCTFail("Expected attached session")
            }
            reconnectAttempts.append(info.sessionName)
        }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(Set(reconnectAttempts), Set(["local-dev", "remote-dev"]))
        XCTAssertEqual(manager.selectedSession?.workspaceID, remoteWorkspaceID)

        let remoteSession = try XCTUnwrap(manager.sessions.first { $0.workspaceID == remoteWorkspaceID })
        if case .attached(let info) = remoteSession.mode {
            XCTAssertEqual(info.host, Fantastty.TmuxHost.ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box", port: 2222)))
            XCTAssertEqual(info.connectionState, .connecting)
        } else {
            XCTFail("Expected restored attached session")
        }
    }

    @MainActor
    func testRestoreTmuxSessionsKeepsDisconnectedPlaceholderWhenReconnectFails() throws {
        let workspaceID = "remote-disconnect-placeholder"
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL
        Fantastty.SessionMetadataStore.shared.remove(forKey: workspaceID)

        let snapshot = Fantastty.LayoutSnapshot(
            workspaces: [
                Fantastty.WorkspaceLayout(
                    workspaceID: workspaceID,
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: Fantastty.TmuxAttachmentInfo(
                        sessionName: "remote-dev",
                        host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box", port: 2222)),
                        connectionState: .disconnected(reason: nil)
                    )
                ),
            ],
            selectedWorkspaceID: workspaceID,
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: layoutURL)

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [] }
        manager.attachedSessionReconnectStarter = { (session: Fantastty.Session) in
            guard case .attached(var info) = session.mode else { return }
            info.connectionState = .disconnected(reason: "offline")
            session.mode = .attached(info)
        }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.count, 1)

        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.workspaceID, workspaceID)
        XCTAssertTrue(restored.tabs.isEmpty)
        XCTAssertEqual(restored.backingState, .missingAttachedBacking(reason: "offline"))
        if case .attached(let info) = restored.mode {
            XCTAssertEqual(info.sessionName, "remote-dev")
            XCTAssertEqual(info.connectionState, .disconnected(reason: "offline"))
        } else {
            XCTFail("Expected restored attached placeholder session")
        }
    }

    @MainActor
    func testRestoreTmuxSessionsRestoresBrowserTabsFromLayout() throws {
        let workspaceID = "restore-browser-tabs"
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL
        let browserURL1 = try XCTUnwrap(URL(string: "https://example.com/one"))
        let browserURL2 = try XCTUnwrap(URL(string: "https://example.com/two"))

        let snapshot = Fantastty.LayoutSnapshot(
            workspaces: [
                Fantastty.WorkspaceLayout(
                    workspaceID: workspaceID,
                    selectedTabIndex: 1,
                    sessionType: .local,
                    attachment: Fantastty.TmuxAttachmentInfo(
                        sessionName: "attached-browser-dev",
                        host: .local,
                        connectionState: .disconnected(reason: nil)
                    ),
                    tabs: [
                        Fantastty.WorkspaceTabLayout(kind: .browser, url: browserURL1),
                        Fantastty.WorkspaceTabLayout(kind: .browser, url: browserURL2),
                    ]
                ),
            ],
            selectedWorkspaceID: workspaceID,
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: layoutURL)

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [] }
        manager.attachedSessionReconnectStarter = { _ in }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.count, 1)

        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.workspaceID, workspaceID)
        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(restored.tabs.map(\.kind), [.browser, .browser])
        XCTAssertEqual(restored.tabs[0].url, browserURL1)
        XCTAssertEqual(restored.tabs[1].url, browserURL2)
        XCTAssertEqual(restored.selectedTabID, restored.tabs[1].id)
    }

    @MainActor
    func testRestoreTmuxSessionsRestoresBrowserTabsWhenTmuxUnavailable() throws {
        let workspaceID = "restore-browser-tabs-tmux-down"
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL
        let browserURL1 = try XCTUnwrap(URL(string: "https://example.com/one"))
        let browserURL2 = try XCTUnwrap(URL(string: "https://example.com/two"))

        let snapshot = Fantastty.LayoutSnapshot(
            workspaces: [
                Fantastty.WorkspaceLayout(
                    workspaceID: workspaceID,
                    selectedTabIndex: 1,
                    sessionType: .local,
                    attachment: Fantastty.TmuxAttachmentInfo(
                        sessionName: "attached-browser-dev",
                        host: .local,
                        connectionState: .disconnected(reason: nil)
                    ),
                    tabs: [
                        Fantastty.WorkspaceTabLayout(kind: .browser, url: browserURL1),
                        Fantastty.WorkspaceTabLayout(kind: .browser, url: browserURL2),
                    ]
                ),
            ],
            selectedWorkspaceID: workspaceID,
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: layoutURL)

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { false }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [] }
        manager.attachedSessionReconnectStarter = { _ in
            XCTFail("Reconnect should not start when tmux is unavailable")
        }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.count, 1)

        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.workspaceID, workspaceID)
        XCTAssertEqual(restored.tabs.map(\.kind), [.browser, .browser])
        XCTAssertEqual(restored.tabs[0].url, browserURL1)
        XCTAssertEqual(restored.tabs[1].url, browserURL2)
        XCTAssertEqual(restored.selectedTabID, restored.tabs[1].id)
        XCTAssertEqual(restored.backingState, .missingAttachedBacking(reason: nil))
        if case .attached(let info) = restored.mode {
            XCTAssertEqual(info.connectionState, .disconnected(reason: nil))
            XCTAssertEqual(info.launchMode, .attach)
        } else {
            XCTFail("Expected restored workspace to remain in attached mode")
        }
    }

    @MainActor
    func testRestoreTmuxSessionsRemapsBrowserSelectedIndexWhenLayoutContainsTerminalEntries() throws {
        let workspaceID = "restore-browser-selected-remap"
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL
        let browserURL1 = try XCTUnwrap(URL(string: "https://example.com/one"))
        let browserURL2 = try XCTUnwrap(URL(string: "https://example.com/two"))

        let snapshot = Fantastty.LayoutSnapshot(
            workspaces: [
                Fantastty.WorkspaceLayout(
                    workspaceID: workspaceID,
                    selectedTabIndex: 2,
                    sessionType: .local,
                    attachment: Fantastty.TmuxAttachmentInfo(
                        sessionName: "attached-browser-dev",
                        host: .local,
                        connectionState: .disconnected(reason: nil)
                    ),
                    tabs: [
                        Fantastty.WorkspaceTabLayout(kind: .terminal),
                        Fantastty.WorkspaceTabLayout(kind: .browser, url: browserURL1),
                        Fantastty.WorkspaceTabLayout(kind: .browser, url: browserURL2),
                    ]
                ),
            ],
            selectedWorkspaceID: workspaceID,
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: layoutURL)

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [] }
        manager.attachedSessionReconnectStarter = { _ in }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.count, 1)

        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.tabs.map(\.kind), [.browser, .browser])
        XCTAssertEqual(restored.tabs[0].url, browserURL1)
        XCTAssertEqual(restored.tabs[1].url, browserURL2)
        XCTAssertEqual(restored.selectedTabID, restored.tabs[1].id)
    }

    @MainActor
    func testRestoreTmuxSessionsRestoresBrowserTabsFromMixedLayout() throws {
        let workspaceID = "restore-browser-tabs"
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL
        let browserURL = try XCTUnwrap(URL(string: "https://example.com/browser"))
        let baseSession = Fantastty.TmuxSessionInfo(
            name: "fantastty-ws-\(workspaceID)",
            createdAt: Date(),
            windowCount: 1
        )

        let snapshot = Fantastty.LayoutSnapshot(
            workspaces: [
                Fantastty.WorkspaceLayout(
                    workspaceID: workspaceID,
                    selectedTabIndex: 1,
                    sessionType: .local,
                    attachment: nil,
                    tabs: [
                        Fantastty.WorkspaceTabLayout(kind: .terminal),
                        Fantastty.WorkspaceTabLayout(kind: .browser, url: browserURL),
                        Fantastty.WorkspaceTabLayout(kind: .terminal),
                    ]
                ),
            ],
            selectedWorkspaceID: workspaceID,
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: layoutURL)

        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = Fantastty.Ghostty.App()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = {
            [
                workspaceID: Fantastty.TmuxWorkspaceInfo(
                    workspaceID: workspaceID,
                    baseSession: baseSession
                )
            ]
        }
        manager.workspaceMetadataProvider = { [] }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.count, 1)

        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.workspaceID, workspaceID)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs.map(\.kind), [.browser])
        XCTAssertEqual(restored.tabs[0].url, browserURL)
        XCTAssertEqual(restored.selectedTabID, restored.tabs[0].id)
    }

    @MainActor
    func testRestoreTmuxSessionsRestoresMetadataOnlyLocalWorkspaceAsAttachedPlaceholder() throws {
        let workspaceID = "placeholder-local-\(UUID().uuidString.prefix(8).lowercased())"
        workspaceIDsToCleanup.append(workspaceID)

        var meta = SessionMetadataStore.shared.getOrCreate(forKey: workspaceID)
        meta.name = "Recovered Workspace"
        meta.noteEntries = [SessionNoteEntry(content: "remember this")]
        meta.attachment = Fantastty.TmuxAttachmentInfo(
            sessionName: "fantastty-ws-\(workspaceID)",
            host: .local,
            connectionState: .disconnected(reason: nil)
        )
        SessionMetadataStore.shared.update(meta)

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [meta] }
        manager.attachedSessionReconnectStarter = { _ in }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.count, 1)

        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.workspaceID, workspaceID)
        XCTAssertEqual(restored.backingState, .available)
        XCTAssertTrue(restored.tabs.isEmpty)
        XCTAssertEqual(restored.title, "Recovered Workspace")
        XCTAssertEqual(restored.notes, "remember this")
        if case .attached(let info) = restored.mode {
            XCTAssertEqual(info.sessionName, "fantastty-ws-\(workspaceID)")
            XCTAssertEqual(info.host, .local)
            XCTAssertEqual(info.connectionState, .connecting)
        } else {
            XCTFail("Expected metadata-only local workspace to restore as attached placeholder")
        }
    }

    @MainActor
    func testRestoreTmuxSessionsRestoresMetadataOnlyRemoteWorkspaceAsAttachedPlaceholder() throws {
        var meta = Fantastty.SessionMetadata(
            workspaceID: "remote-placeholder",
            name: "Remote Placeholder",
            attachment: Fantastty.TmuxAttachmentInfo(
                sessionName: "tmux-remote-placeholder",
                host: .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box.example.com", port: 2222)),
                connectionState: .disconnected(reason: nil)
            )
        )
        meta.modifiedAt = Date()

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [meta] }
        manager.attachedSessionReconnectStarter = { _ in }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.count, 1)

        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.workspaceID, meta.workspaceID)
        XCTAssertTrue(restored.tabs.isEmpty)
        XCTAssertEqual(restored.backingState, .available)
        if case .attached(let info) = restored.mode {
            XCTAssertEqual(info.sessionName, "tmux-remote-placeholder")
            XCTAssertEqual(
                info.host,
                .ssh(Fantastty.SSHHostInfo(user: "me", hostname: "box.example.com", port: 2222))
            )
            XCTAssertEqual(info.connectionState, .connecting)
        } else {
            XCTFail("Expected metadata-only remote workspace to restore as attached placeholder")
        }
    }

    @MainActor
    func testRestoreTmuxSessionsSkipsTrashedMetadataWorkspaces() throws {
        let workspaceID = "trashed-placeholder-\(UUID().uuidString.prefix(8).lowercased())"
        workspaceIDsToCleanup.append(workspaceID)

        var meta = SessionMetadataStore.shared.getOrCreate(forKey: workspaceID)
        meta.name = "Do Not Restore"
        meta.isTrashed = true
        meta.trashedAt = Date()
        SessionMetadataStore.shared.update(meta)

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [meta] }

        XCTAssertFalse(manager.restoreTmuxSessions())
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    @MainActor
    func testRestoreTrashedWorkspaceClearsTrashAndRecreatesSession() {
        let workspaceID = "restore-trash-\(UUID().uuidString.prefix(8).lowercased())"
        workspaceIDsToCleanup.append(workspaceID)

        var meta = SessionMetadataStore.shared.getOrCreate(forKey: workspaceID)
        meta.name = "Restore Me"
        meta.isTrashed = true
        meta.trashedAt = Date()
        SessionMetadataStore.shared.update(meta)

        let manager = Fantastty.SessionManager()
        manager.ghosttyApp = Fantastty.Ghostty.App()
        manager.persistentSessionsEnabled = false

        manager.restoreTrashedWorkspace(workspaceID: workspaceID)

        let restoredMeta = SessionMetadataStore.shared.getOrCreate(forKey: workspaceID)
        XCTAssertFalse(restoredMeta.isTrashed)
        XCTAssertNil(restoredMeta.trashedAt)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.sessions.first?.workspaceID, workspaceID)
    }

    @MainActor
    func testRestoreTmuxSessionsUsesLayoutOrderForMetadataPlaceholders() throws {
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL

        let snapshot = Fantastty.LayoutSnapshot(
            workspaces: [
                Fantastty.WorkspaceLayout(
                    workspaceID: "workspace-b",
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: nil
                ),
                Fantastty.WorkspaceLayout(
                    workspaceID: "workspace-a",
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: nil
                ),
            ],
            selectedWorkspaceID: "workspace-a",
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: layoutURL)

        var firstMeta = SessionMetadata(workspaceID: "workspace-a", name: "First")
        firstMeta.modifiedAt = Date(timeIntervalSince1970: 100)
        var secondMeta = SessionMetadata(workspaceID: "workspace-b", name: "Second")
        secondMeta.modifiedAt = Date(timeIntervalSince1970: 200)

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [firstMeta, secondMeta] }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.map(\.workspaceID), ["workspace-b", "workspace-a"])
        XCTAssertEqual(manager.selectedSession?.workspaceID, "workspace-a")
    }

    @MainActor
    func testRestoreTmuxSessionsWithoutLayoutSortsMetadataPlaceholdersByModifiedAtDescending() {
        var olderMeta = SessionMetadata(workspaceID: "workspace-old", name: "Older")
        olderMeta.modifiedAt = Date(timeIntervalSince1970: 100)
        var newerMeta = SessionMetadata(workspaceID: "workspace-new", name: "Newer")
        newerMeta.modifiedAt = Date(timeIntervalSince1970: 200)

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [olderMeta, newerMeta] }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.map(\.workspaceID), ["workspace-new", "workspace-old"])
        XCTAssertEqual(manager.selectedSession?.workspaceID, "workspace-new")
    }

    @MainActor
    func testRestoreTmuxSessionsWithoutLayoutRestoresLiveWorkspaceAsAttached() throws {
        let layoutURL = tempFileURL()
        Fantastty.SessionManager.layoutURLOverride = layoutURL

        let workspaceID = "live-without-layout"
        let baseSession = Fantastty.TmuxSessionInfo(
            name: "fantastty-ws-\(workspaceID)",
            createdAt: Date(),
            windowCount: 1
        )

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = {
            [
                workspaceID: Fantastty.TmuxWorkspaceInfo(
                    workspaceID: workspaceID,
                    baseSession: baseSession
                )
            ]
        }
        manager.workspaceMetadataProvider = { [] }
        manager.attachedSessionReconnectStarter = { _ in }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.count, 1)

        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.workspaceID, workspaceID)
        if case .attached(let info) = restored.mode {
            XCTAssertEqual(info.sessionName, baseSession.name)
            XCTAssertEqual(info.host, .local)
            XCTAssertEqual(info.connectionState, .connecting)
        } else {
            XCTFail("Expected live workspace without layout to restore as attached")
        }
    }

    @MainActor
    func testRestoreTmuxSessionsRestoresLegacyLayoutAsAttachedSession() throws {
        let tempDir = tempDirectoryURL()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let layoutURL = tempDir.appendingPathComponent("layout.json")
        Fantastty.SessionManager.layoutURLOverride = layoutURL

        let workspaceID = "legacy-restore"
        let snapshot = Fantastty.LayoutSnapshot(
            schemaVersion: 0,
            workspaces: [
                Fantastty.WorkspaceLayout(
                    workspaceID: workspaceID,
                    selectedTabIndex: 0,
                    sessionType: .local,
                    attachment: nil,
                    tabs: [Fantastty.WorkspaceTabLayout(kind: .terminal)]
                )
            ],
            selectedWorkspaceID: workspaceID,
            savedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: layoutURL)

        let manager = Fantastty.SessionManager()
        manager.persistentSessionsEnabled = true
        manager.tmuxAvailabilityProvider = { true }
        manager.liveTmuxWorkspaceProvider = { [:] }
        manager.workspaceMetadataProvider = { [] }
        manager.attachedSessionReconnectStarter = { _ in }

        XCTAssertTrue(manager.restoreTmuxSessions())
        XCTAssertEqual(manager.sessions.count, 1)

        let restored = try XCTUnwrap(manager.sessions.first)
        XCTAssertEqual(restored.workspaceID, workspaceID)
        XCTAssertEqual(restored.tabs.map(\.kind), [])
        if case .attached(let info) = restored.mode {
            XCTAssertEqual(info.sessionName, "fantastty-ws-\(workspaceID)")
            XCTAssertEqual(info.host, .local)
            XCTAssertEqual(info.connectionState, .connecting)
        } else {
            XCTFail("Expected migrated restore to produce an attached session")
        }
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

    private func tempDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fantastty-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
