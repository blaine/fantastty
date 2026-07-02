import XCTest
@testable import Fantastty

final class TmuxAttachmentInfoTests: XCTestCase {
    private let sshConnectionOptions = "-o ControlMaster=no -o ControlPath=none -o KexAlgorithms=curve25519-sha256,sntrup761x25519-sha512,sntrup761x25519-sha512@openssh.com,curve25519-sha256@libssh.org"

    // MARK: - SSHHostInfo.displayName

    func testSSHHostInfoDisplayNameSimple() {
        let info = SSHHostInfo(user: nil, hostname: "example.com", port: nil)
        XCTAssertEqual(info.displayName, "example.com")
    }

    func testSSHHostInfoDisplayNameWithUser() {
        let info = SSHHostInfo(user: "alice", hostname: "example.com", port: nil)
        XCTAssertEqual(info.displayName, "alice@example.com")
    }

    func testSSHHostInfoDisplayNameWithNon22Port() {
        let info = SSHHostInfo(user: nil, hostname: "example.com", port: 2222)
        XCTAssertEqual(info.displayName, "example.com:2222")
    }

    func testSSHHostInfoDisplayNameWithPort22Omitted() {
        let info = SSHHostInfo(user: nil, hostname: "example.com", port: 22)
        XCTAssertEqual(info.displayName, "example.com")
    }

    func testSSHHostInfoDisplayNameFull() {
        let info = SSHHostInfo(user: "alice", hostname: "example.com", port: 2222)
        XCTAssertEqual(info.displayName, "alice@example.com:2222")
    }

    // MARK: - SSHHostInfo.sshCommandPrefix

    func testSSHCommandPrefixSimple() {
        let info = SSHHostInfo(user: nil, hostname: "example.com", port: nil)
        XCTAssertEqual(
            info.sshCommandPrefix,
            "ssh -t \(sshConnectionOptions) -- 'example.com'"
        )
    }

    func testSSHCommandPrefixFull() {
        let info = SSHHostInfo(user: "alice", hostname: "example.com", port: 2222)
        XCTAssertEqual(
            info.sshCommandPrefix,
            "ssh -t \(sshConnectionOptions) -p 2222 -- 'alice@example.com'"
        )
    }

    // MARK: - TmuxHost.displayName

    func testTmuxHostLocalDisplayName() {
        let host = TmuxHost.local
        XCTAssertEqual(host.displayName, "localhost")
    }

    func testTmuxHostSSHDisplayName() {
        let sshInfo = SSHHostInfo(user: "bob", hostname: "server.io", port: nil)
        let host = TmuxHost.ssh(sshInfo)
        XCTAssertEqual(host.displayName, "bob@server.io")
    }

    // MARK: - TmuxAttachmentInfo.controlCommand

    func testControlCommandLocal() {
        let info = TmuxAttachmentInfo(
            sessionName: "mysession",
            host: .local,
            connectionState: .connecting
        )
        XCTAssertEqual(info.controlCommand(), "tmux -CC attach-session -t 'mysession'")
    }

    func testControlCommandRemote() {
        let sshInfo = SSHHostInfo(user: "alice", hostname: "example.com", port: 2222)
        let info = TmuxAttachmentInfo(
            sessionName: "work",
            host: .ssh(sshInfo),
            connectionState: .connected
        )
        XCTAssertEqual(
            info.controlCommand(),
            "ssh -t \(sshConnectionOptions) -p 2222 -- 'alice@example.com' 'tmux -CC attach-session -t '\\''work'\\'''"
        )
    }

    func testControlCommandCustomTmuxPath() {
        let info = TmuxAttachmentInfo(
            sessionName: "dev",
            host: .local,
            connectionState: .connecting
        )
        XCTAssertEqual(
            info.controlCommand(tmuxPath: "/opt/homebrew/bin/tmux"),
            "/opt/homebrew/bin/tmux -CC attach-session -t 'dev'"
        )
    }

    func testControlCommandForCreateStillAttaches() {
        let info = TmuxAttachmentInfo(
            sessionName: "fresh",
            host: .local,
            connectionState: .connecting,
            launchMode: .create
        )

        XCTAssertEqual(info.controlCommand(), "tmux -CC attach-session -t 'fresh'")
    }

    func testControlCommandEscapesSingleQuoteSessionName() {
        let info = TmuxAttachmentInfo(
            sessionName: "Jesse's work",
            host: .local,
            connectionState: .connecting
        )

        XCTAssertEqual(info.controlCommand(), "tmux -CC attach-session -t 'Jesse'\\''s work'")
    }

    func testRemoteControlCommandPassesQuotedTmuxCommandToSSH() {
        let sshInfo = SSHHostInfo(user: "alice", hostname: "example.com", port: 2222)
        let info = TmuxAttachmentInfo(
            sessionName: "work session",
            host: .ssh(sshInfo),
            connectionState: .connected
        )

        XCTAssertEqual(
            info.controlCommand(),
            "ssh -t \(sshConnectionOptions) -p 2222 -- 'alice@example.com' 'tmux -CC attach-session -t '\\''work session'\\'''"
        )
    }

    func testCreateSessionCommandLocal() {
        let info = TmuxAttachmentInfo(
            sessionName: "fresh",
            host: .local,
            connectionState: .connecting,
            launchMode: .create
        )

        XCTAssertEqual(
            info.createSessionCommand(),
            "tmux has-session -t 'fresh' 2>/dev/null || tmux new-session -d -s 'fresh' -c ~"
        )
    }

    func testCreateSessionCommandEscapesSingleQuoteSessionName() {
        let info = TmuxAttachmentInfo(
            sessionName: "Jesse's work",
            host: .local,
            connectionState: .connecting,
            launchMode: .create
        )

        XCTAssertEqual(
            info.createSessionCommand(),
            "tmux has-session -t 'Jesse'\\''s work' 2>/dev/null || tmux new-session -d -s 'Jesse'\\''s work' -c ~"
        )
    }

    func testCreateSessionCommandRemote() {
        let sshInfo = SSHHostInfo(user: "alice", hostname: "example.com", port: 2222)
        let info = TmuxAttachmentInfo(
            sessionName: "work",
            host: .ssh(sshInfo),
            connectionState: .connecting,
            launchMode: .create
        )

        XCTAssertEqual(
            info.createSessionCommand(),
            "ssh -t \(sshConnectionOptions) -p 2222 -- 'alice@example.com' 'tmux has-session -t '\\''work'\\'' 2>/dev/null || tmux new-session -d -s '\\''work'\\'' -c ~'"
        )
    }

    // MARK: - Codable Round-Trips: SSHHostInfo

    func testSSHHostInfoCodableRoundTrip() throws {
        let original = SSHHostInfo(user: "alice", hostname: "example.com", port: 2222)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSHHostInfo.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Codable Round-Trips: TmuxHost

    func testTmuxHostLocalCodableRoundTrip() throws {
        let original = TmuxHost.local
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TmuxHost.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testTmuxHostSSHCodableRoundTrip() throws {
        let sshInfo = SSHHostInfo(user: "bob", hostname: "server.io", port: nil)
        let original = TmuxHost.ssh(sshInfo)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TmuxHost.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Codable Round-Trips: ConnectionState

    func testConnectionStateConnectingCodableRoundTrip() throws {
        let original = ConnectionState.connecting
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionState.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testConnectionStateConnectedCodableRoundTrip() throws {
        let original = ConnectionState.connected
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionState.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testConnectionStateReconnectingCodableRoundTrip() throws {
        let original = ConnectionState.reconnecting(reason: "Socket is not connected")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionState.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testConnectionStateDisconnectedWithReasonCodableRoundTrip() throws {
        let original = ConnectionState.disconnected(reason: "timeout")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionState.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testConnectionStateDisconnectedWithoutReasonCodableRoundTrip() throws {
        let original = ConnectionState.disconnected(reason: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionState.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Codable Round-Trips: TmuxAttachmentInfo

    func testTmuxAttachmentInfoCodableRoundTrip() throws {
        let sshInfo = SSHHostInfo(user: "alice", hostname: "example.com", port: 2222)
        let original = TmuxAttachmentInfo(
            sessionName: "work",
            host: .ssh(sshInfo),
            connectionState: .connected,
            transport: .remoteEngine
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TmuxAttachmentInfo.self, from: data)
        XCTAssertEqual(original, decoded)
        XCTAssertEqual(decoded.transport, .remoteEngine)
    }

    // MARK: - Codable Round-Trips: SessionMode

    func testSessionModeAttachedCodableRoundTrip() throws {
        let info = TmuxAttachmentInfo(
            sessionName: "dev",
            host: .local,
            connectionState: .disconnected(reason: "user detached")
        )
        let original = SessionMode.attached(info)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionMode.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
