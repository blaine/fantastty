import XCTest
@testable import Fantastty

final class TmuxAttachUITests: XCTestCase {

    // MARK: - Host string parsing

    func testParseHostnameOnly() {
        let host = TmuxAttachSheet.parseHostString("dev.example.com")
        XCTAssertNotNil(host)
        XCTAssertNil(host?.user)
        XCTAssertEqual(host?.hostname, "dev.example.com")
        XCTAssertNil(host?.port)
    }

    func testParseUserAtHost() {
        let host = TmuxAttachSheet.parseHostString("deploy@prod.example.com")
        XCTAssertEqual(host?.user, "deploy")
        XCTAssertEqual(host?.hostname, "prod.example.com")
        XCTAssertNil(host?.port)
    }

    func testParseHostnameWithPort() {
        let host = TmuxAttachSheet.parseHostString("dev.example.com:2222")
        XCTAssertNil(host?.user)
        XCTAssertEqual(host?.hostname, "dev.example.com")
        XCTAssertEqual(host?.port, 2222)
    }

    func testParseFullHostString() {
        let host = TmuxAttachSheet.parseHostString("deploy@prod.example.com:2222")
        XCTAssertEqual(host?.user, "deploy")
        XCTAssertEqual(host?.hostname, "prod.example.com")
        XCTAssertEqual(host?.port, 2222)
    }

    func testParseEmptyStringReturnsNil() {
        XCTAssertNil(TmuxAttachSheet.parseHostString(""))
    }

    func testParseJustAtSignReturnsNil() {
        XCTAssertNil(TmuxAttachSheet.parseHostString("@"))
    }

    func testParseIPv4() {
        let host = TmuxAttachSheet.parseHostString("192.168.1.100")
        XCTAssertEqual(host?.hostname, "192.168.1.100")
    }

    func testParseIPv4WithPort() {
        let host = TmuxAttachSheet.parseHostString("192.168.1.100:22")
        XCTAssertEqual(host?.hostname, "192.168.1.100")
        XCTAssertEqual(host?.port, 22)
    }

    // MARK: - Session filtering

    func testFilterByName() {
        let sessions = [
            TmuxAttachSheet.DiscoveredSession(name: "my-project", host: .local, windowCount: 2),
            TmuxAttachSheet.DiscoveredSession(name: "dev-server", host: .local, windowCount: 1),
            TmuxAttachSheet.DiscoveredSession(name: "other", host: .local, windowCount: 3),
        ]
        let filtered = TmuxAttachSheet.filterSessions(sessions, by: "dev")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name, "dev-server")
    }

    func testFilterByHostname() {
        let sessions = [
            TmuxAttachSheet.DiscoveredSession(name: "work", host: .local, windowCount: 1),
            TmuxAttachSheet.DiscoveredSession(
                name: "work",
                host: .ssh(SSHHostInfo(user: nil, hostname: "prod.example.com", port: nil)),
                windowCount: 1
            ),
        ]
        let filtered = TmuxAttachSheet.filterSessions(sessions, by: "prod")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.host.displayName, "prod.example.com")
    }

    func testEmptyFilterReturnsAll() {
        let sessions = [
            TmuxAttachSheet.DiscoveredSession(name: "a", host: .local, windowCount: 1),
            TmuxAttachSheet.DiscoveredSession(name: "b", host: .local, windowCount: 2),
        ]
        let filtered = TmuxAttachSheet.filterSessions(sessions, by: "")
        XCTAssertEqual(filtered.count, 2)
    }

    func testFilterIsCaseInsensitive() {
        let sessions = [
            TmuxAttachSheet.DiscoveredSession(name: "MyProject", host: .local, windowCount: 1),
        ]
        let filtered = TmuxAttachSheet.filterSessions(sessions, by: "myproject")
        XCTAssertEqual(filtered.count, 1)
    }
    func testDiscoverLocalSessionsMapsTmuxSessions() {
        let sessions = TmuxAttachSheet.discoverSessions(
            isLocal: true,
            hostString: "",
            listLocal: {
                [
                    TmuxSessionInfo(name: "alpha", createdAt: .distantPast, windowCount: 2),
                    TmuxSessionInfo(name: "beta", createdAt: .distantPast, windowCount: 1),
                ]
            },
            listRemote: { _ in
                XCTFail("Remote discovery should not be used for local sessions")
                return []
            }
        )

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map(\.name), ["alpha", "beta"])
        XCTAssertTrue(sessions.allSatisfy { $0.host == .local })
    }

    func testDiscoverRemoteSessionsRequiresValidHostString() {
        let sessions = TmuxAttachSheet.discoverSessions(
            isLocal: false,
            hostString: "",
            listLocal: {
                XCTFail("Local discovery should not be used for remote sessions")
                return []
            },
            listRemote: { _ in
                XCTFail("Remote discovery should not run for invalid host strings")
                return []
            }
        )

        XCTAssertTrue(sessions.isEmpty)
    }
}
