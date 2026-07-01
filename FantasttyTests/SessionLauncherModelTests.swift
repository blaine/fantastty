import XCTest
@testable import Fantastty

final class SessionLauncherModelTests: XCTestCase {
    func testSSHConnectionNormalizesDefaultPort() {
        let draft = SessionLauncherConnectionDraft(host: " remote.example.invalid ", user: " jesse ", port: "22", useRemoteEngine: false)

        let host = draft.sshHostInfo

        XCTAssertEqual(host, SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil))
    }

    func testSSHConnectionRejectsBlankHost() {
        let draft = SessionLauncherConnectionDraft(host: " ", user: "jesse", port: "22", useRemoteEngine: false)

        XCTAssertNil(draft.sshHostInfo)
        XCTAssertFalse(draft.canDiscover)
    }

    func testSSHConnectionRejectsInvalidPort() {
        let draft = SessionLauncherConnectionDraft(host: "remote.example.invalid", user: "", port: "nope", useRemoteEngine: false)

        XCTAssertNil(draft.sshHostInfo)
        XCTAssertFalse(draft.canDiscover)
    }

    func testSessionRowsStartWithNewSession() {
        let rows = SessionLauncherSessionList.rows(
            for: [
                .tmux(name: "steady-pine", host: .local, windowCount: 3),
                .tmux(name: "release-work", host: .local, windowCount: 1),
            ],
            attachedKeys: []
        )

        XCTAssertEqual(rows.map(\.title), ["New session", "steady-pine", "release-work"])
        XCTAssertEqual(rows.first?.selection, .newSession)
    }

    func testAttachedSessionsAreFilteredFromExistingRows() {
        let rows = SessionLauncherSessionList.rows(
            for: [
                .tmux(name: "steady-pine", host: .local, windowCount: 3),
                .tmux(name: "release-work", host: .local, windowCount: 1),
            ],
            attachedKeys: [
                AttachedSessionKey(sessionName: "steady-pine", host: .local)
            ]
        )

        XCTAssertEqual(rows.map(\.title), ["New session", "release-work"])
    }

    func testFilterMatchesSessionNameAndHost() {
        let sessions = [
            SessionLauncherDiscoveredSession.tmux(name: "steady-pine", host: .local, windowCount: 3),
            .tmux(
                name: "build",
                host: .ssh(SSHHostInfo(user: "jesse", hostname: "magic-kingdom", port: nil)),
                windowCount: 1
            ),
        ]
        let nameRows = SessionLauncherSessionList.rows(
            for: sessions,
            attachedKeys: [],
            filter: "steady"
        )
        let hostRows = SessionLauncherSessionList.rows(
            for: sessions,
            attachedKeys: [],
            filter: "magic"
        )

        XCTAssertEqual(nameRows.map(\.title), ["New session", "steady-pine"])
        XCTAssertEqual(hostRows.map(\.title), ["New session", "build"])
    }

    func testExistingSSHSessionUsesRemoteEngineTransportWhenChecked() {
        let host = SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let action = SessionLauncherAction.existingTmuxAction(
            name: "steady-pine",
            host: .ssh(host),
            useRemoteEngine: true
        )

        XCTAssertEqual(action, .attachTmux(TmuxAttachmentInfo(
            sessionName: "steady-pine",
            host: .ssh(host),
            connectionState: .disconnected(reason: nil),
            launchMode: .attach,
            transport: .remoteEngine
        )))
    }

    func testExistingSSHSessionUsesTmuxControlWhenRemoteEngineUnchecked() {
        let host = SSHHostInfo(user: nil, hostname: "remote.example.invalid", port: 2222)
        let action = SessionLauncherAction.existingTmuxAction(
            name: "steady-pine",
            host: .ssh(host),
            useRemoteEngine: false
        )

        XCTAssertEqual(action, .attachTmux(TmuxAttachmentInfo(
            sessionName: "steady-pine",
            host: .ssh(host),
            connectionState: .disconnected(reason: nil),
            launchMode: .attach,
            transport: .tmuxControl
        )))
    }

    func testNewSSHSessionUsesRemoteEngineWhenChecked() {
        let host = SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let action = SessionLauncherAction.newSessionAction(
            location: .ssh,
            sshHost: host,
            spriteName: "",
            useRemoteEngine: true
        )

        XCTAssertEqual(action, .createRemoteEngine(host))
    }

    func testNewSSHSessionUsesPlainSSHWhenUnchecked() {
        let host = SSHHostInfo(user: "jesse", hostname: "remote.example.invalid", port: nil)
        let action = SessionLauncherAction.newSessionAction(
            location: .ssh,
            sshHost: host,
            spriteName: "",
            useRemoteEngine: false
        )

        XCTAssertEqual(action, .createSession(.ssh(host: "remote.example.invalid", user: "jesse", port: nil)))
    }
}
