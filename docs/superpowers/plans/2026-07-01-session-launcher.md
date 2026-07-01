# Session Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the separate SSH, Sprite, and tmux attach panels with one location-first New Workspace launcher.

**Architecture:** Add a small testable launcher model that decides location, connection, row selection, and resulting action. Build a SwiftUI sheet on top of that model, then route existing menu/sidebar entry points to the unified sheet. Keep session creation, tmux attachment, remote-engine startup, and Sprite CLI behavior in the existing managers.

**Tech Stack:** Swift, SwiftUI, XCTest, XcodeGen-managed Xcode project.

---

## File Structure

- Create `Fantastty/Models/SessionLauncherModel.swift`
  - Pure enums and structs for launcher location, presentation request, connection drafts, discovered rows, selected row, filtering, validation, and conversion to session actions.
- Create `Fantastty/Views/SessionLauncher/SessionLauncherSheet.swift`
  - The unified sheet layout: left location rail, connection form, session list, loading/error/empty states, and footer actions.
- Modify `Fantastty/Views/MainWindow.swift`
  - Present the unified sheet via one `.sheet(item:)`.
- Modify `Fantastty/Models/SessionManager.swift`
  - Replace separate creation sheet booleans with one launcher request and add small methods that perform launcher actions using existing manager methods.
- Modify `Fantastty/Views/Sidebar/NewSessionMenu.swift`, `Fantastty/Views/Sidebar/SidebarView.swift`, and `Fantastty/App/AppCommands.swift`
  - Route existing New Workspace, SSH, Sprite, and tmux attach commands to the launcher or direct local fast path.
- Modify or remove obsolete view files after wiring is complete:
  - `Fantastty/Views/SSH/SSHConnectionSheet.swift`
  - `Fantastty/Views/Sprite/SpriteConnectionSheet.swift`
  - `Fantastty/Views/Tmux/TmuxAttachSheet.swift`
- Create `FantasttyTests/SessionLauncherModelTests.swift`
  - Focused behavior tests for parsing, list building, filtering, validation, transport selection, and action routing.
- Modify `FantasttyTests/TmuxAttachUITests.swift`
  - Move assertions that still matter to the new model tests, then remove tests for deleted sheet types.
- Modify `Fantastty.xcodeproj/project.pbxproj`
  - Regenerate with XcodeGen after adding/removing Swift files.

## Task 1: Add Launcher Model Tests

**Files:**
- Create: `FantasttyTests/SessionLauncherModelTests.swift`
- Create in Task 2: `Fantastty/Models/SessionLauncherModel.swift`

- [ ] **Step 1: Write failing tests for SSH connection normalization and row actions**

Create `FantasttyTests/SessionLauncherModelTests.swift`:

```swift
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
        let rows = SessionLauncherSessionList.rows(
            for: [
                .tmux(name: "steady-pine", host: .local, windowCount: 3),
                .tmux(
                    name: "build",
                    host: .ssh(SSHHostInfo(user: "jesse", hostname: "magic-kingdom", port: nil)),
                    windowCount: 1
                ),
            ],
            attachedKeys: [],
            filter: "magic"
        )

        XCTAssertEqual(rows.map(\.title), ["New session", "build"])
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
```

- [ ] **Step 2: Run the new tests and verify they fail because model types do not exist**

Run:

```bash
xcodebuild -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/SessionLauncherModelTests test
```

Expected: compile fails with errors such as `cannot find 'SessionLauncherConnectionDraft' in scope`.

- [ ] **Step 3: Commit the failing tests only if the team wants red commits**

Default for this repo: do not commit an intentionally failing state unless Jesse explicitly asks for red commits. Keep the tests unstaged until Task 2 turns them green.

## Task 2: Implement Testable Launcher Model

**Files:**
- Create: `Fantastty/Models/SessionLauncherModel.swift`
- Modify: `Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift`
- Test: `FantasttyTests/SessionLauncherModelTests.swift`

- [ ] **Step 1: Move attached-session key into model code**

Add this near `TmuxHost` in `Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift`:

```swift
struct AttachedSessionKey: Hashable {
    let sessionName: String
    let host: TmuxHost
}
```

- [ ] **Step 2: Add the launcher model**

Create `Fantastty/Models/SessionLauncherModel.swift`:

```swift
import Foundation

enum SessionLauncherLocation: String, CaseIterable, Identifiable {
    case local
    case ssh
    case sprite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "This Mac"
        case .ssh: return "SSH host"
        case .sprite: return "Sprite"
        }
    }

    var subtitle: String {
        switch self {
        case .local: return "Local shell or local tmux"
        case .ssh: return "Remote shell or remote tmux"
        case .sprite: return "Sprite sessions"
        }
    }
}

struct SessionLauncherRequest: Identifiable, Equatable {
    enum Focus: Equatable {
        case newSession
        case existingSessions
    }

    let id = UUID()
    var location: SessionLauncherLocation
    var focus: Focus

    static func local(focus: Focus = .newSession) -> SessionLauncherRequest {
        SessionLauncherRequest(location: .local, focus: focus)
    }

    static func ssh(focus: Focus = .newSession) -> SessionLauncherRequest {
        SessionLauncherRequest(location: .ssh, focus: focus)
    }

    static func sprite(focus: Focus = .newSession) -> SessionLauncherRequest {
        SessionLauncherRequest(location: .sprite, focus: focus)
    }
}

struct SessionLauncherConnectionDraft: Equatable {
    var host: String = ""
    var user: String = ""
    var port: String = "22"
    var useRemoteEngine: Bool = false

    var sshHostInfo: SSHHostInfo? {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else { return nil }

        let normalizedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort: Int?
        if normalizedPort.isEmpty || normalizedPort == "22" {
            parsedPort = nil
        } else if let value = Int(normalizedPort), value > 0 {
            parsedPort = value
        } else {
            return nil
        }

        return SSHHostInfo(
            user: normalizedUser.isEmpty ? nil : normalizedUser,
            hostname: normalizedHost,
            port: parsedPort
        )
    }

    var canDiscover: Bool {
        sshHostInfo != nil
    }
}

enum SessionLauncherDiscoveredSession: Equatable {
    case tmux(name: String, host: TmuxHost, windowCount: Int)
    case sprite(name: String)

    var title: String {
        switch self {
        case .tmux(let name, _, _), .sprite(let name):
            return name
        }
    }

    var hostDisplayName: String {
        switch self {
        case .tmux(_, let host, _):
            return host.displayName
        case .sprite:
            return "Sprite"
        }
    }

    var attachedKey: AttachedSessionKey? {
        switch self {
        case .tmux(let name, let host, _):
            return AttachedSessionKey(sessionName: name, host: host)
        case .sprite:
            return nil
        }
    }
}

enum SessionLauncherSelection: Equatable {
    case newSession
    case existing(SessionLauncherDiscoveredSession)
}

struct SessionLauncherRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let selection: SessionLauncherSelection
}

enum SessionLauncherSessionList {
    static func rows(
        for sessions: [SessionLauncherDiscoveredSession],
        attachedKeys: Set<AttachedSessionKey>,
        filter: String = ""
    ) -> [SessionLauncherRow] {
        let normalizedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingRows = sessions
            .filter { session in
                guard let key = session.attachedKey else { return true }
                return !attachedKeys.contains(key)
            }
            .filter { session in
                guard !normalizedFilter.isEmpty else { return true }
                return session.title.localizedCaseInsensitiveContains(normalizedFilter)
                    || session.hostDisplayName.localizedCaseInsensitiveContains(normalizedFilter)
            }
            .map(row(for:))

        return [newSessionRow] + existingRows
    }

    private static var newSessionRow: SessionLauncherRow {
        SessionLauncherRow(
            id: "new-session",
            title: "New session",
            subtitle: "Start a fresh session at this location.",
            selection: .newSession
        )
    }

    private static func row(for session: SessionLauncherDiscoveredSession) -> SessionLauncherRow {
        switch session {
        case .tmux(let name, let host, let windowCount):
            return SessionLauncherRow(
                id: "tmux-\(host.displayName)-\(name)",
                title: name,
                subtitle: "\(windowCount) window\(windowCount == 1 ? "" : "s") · \(host.displayName)",
                selection: .existing(session)
            )
        case .sprite(let name):
            return SessionLauncherRow(
                id: "sprite-\(name)",
                title: name,
                subtitle: "Sprite session",
                selection: .existing(session)
            )
        }
    }
}

enum SessionLauncherAction: Equatable {
    case createSession(SessionType)
    case createRemoteEngine(SSHHostInfo)
    case createSprite(name: String?)
    case attachTmux(TmuxAttachmentInfo)
    case connectSprite(String)

    static func newSessionAction(
        location: SessionLauncherLocation,
        sshHost: SSHHostInfo?,
        spriteName: String,
        useRemoteEngine: Bool
    ) -> SessionLauncherAction? {
        switch location {
        case .local:
            return .createSession(.local)
        case .ssh:
            guard let sshHost else { return nil }
            if useRemoteEngine {
                return .createRemoteEngine(sshHost)
            }
            return .createSession(.ssh(host: sshHost.hostname, user: sshHost.user, port: sshHost.port))
        case .sprite:
            let normalizedName = spriteName.trimmingCharacters(in: .whitespacesAndNewlines)
            return .createSprite(name: normalizedName.isEmpty ? nil : normalizedName)
        }
    }

    static func existingTmuxAction(
        name: String,
        host: TmuxHost,
        useRemoteEngine: Bool
    ) -> SessionLauncherAction {
        let transport: TmuxAttachmentTransport
        if useRemoteEngine, case .ssh = host {
            transport = .remoteEngine
        } else {
            transport = .tmuxControl
        }

        return .attachTmux(TmuxAttachmentInfo(
            sessionName: name,
            host: host,
            connectionState: .disconnected(reason: nil),
            launchMode: .attach,
            transport: transport
        ))
    }
}
```

- [ ] **Step 3: Run model tests and verify they pass**

Run:

```bash
xcodebuild -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/SessionLauncherModelTests test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit model and tests**

Run:

```bash
git status --short
git add Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift Fantastty/Models/SessionLauncherModel.swift FantasttyTests/SessionLauncherModelTests.swift
git commit -m "Add session launcher model" -m "Introduces the testable location-first launcher model before adding SwiftUI. The model keeps remote engine as an SSH connection checkbox, treats New session as the first row, filters already-attached tmux sessions, and converts selections into existing SessionManager actions."
```

## Task 3: Build Unified Launcher Sheet

**Files:**
- Create: `Fantastty/Views/SessionLauncher/SessionLauncherSheet.swift`
- Modify: `Fantastty/Models/SessionManager.swift`
- Test: `FantasttyTests/SessionLauncherModelTests.swift`

- [ ] **Step 1: Add manager presentation and action methods**

In `Fantastty/Models/SessionManager.swift`, replace the three sheet booleans with one request:

```swift
    /// Unified New Workspace launcher request.
    @Published var sessionLauncherRequest: SessionLauncherRequest?
```

Add these methods near the existing session creation methods:

```swift
    func showSessionLauncher(_ request: SessionLauncherRequest = .local()) {
        sessionLauncherRequest = request
    }

    func performSessionLauncherAction(_ action: SessionLauncherAction) {
        switch action {
        case .createSession(let type):
            createSession(type: type)
        case .createRemoteEngine(let host):
            createRemoteEngineSession(host: host)
        case .attachTmux(let info):
            attachToTmuxSession(info: info)
        case .connectSprite(let name):
            createSession(type: .sprite(name: name))
        case .createSprite:
            assertionFailure("Sprite creation is asynchronous and must be handled by SessionLauncherSheet.")
        }
    }
```

Keep the old booleans in place until Task 4 if deleting them breaks compilation. If they remain temporarily, mark them only by usage and remove them in Task 4.

- [ ] **Step 2: Create the SwiftUI launcher sheet**

Create `Fantastty/Views/SessionLauncher/SessionLauncherSheet.swift`:

```swift
import SwiftUI

struct SessionLauncherSheet: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    let request: SessionLauncherRequest

    @State private var location: SessionLauncherLocation
    @State private var sshDraft = SessionLauncherConnectionDraft()
    @State private var spriteName = ""
    @State private var filter = ""
    @State private var discoveredSessions: [SessionLauncherDiscoveredSession] = []
    @State private var selectedRowID: String? = "new-session"
    @State private var isDiscovering = false
    @State private var isCreatingSprite = false
    @State private var discoveryError: String?
    @State private var discoveryTask: Task<Void, Never>?

    init(request: SessionLauncherRequest) {
        self.request = request
        _location = State(initialValue: request.location)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                locationRail
                Divider()
                detailPane
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 520)
        .onAppear {
            selectedRowID = request.focus == .existingSessions ? firstExistingRowID ?? "new-session" : "new-session"
            refreshDiscovery()
        }
        .onChange(of: location) {
            filter = ""
            selectedRowID = "new-session"
            discoveryError = nil
            refreshDiscovery()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("New Workspace")
                    .font(.headline)
                Text("Choose where the session lives, then choose what to open there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var locationRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Where?")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.bottom, 4)

            ForEach(SessionLauncherLocation.allCases) { item in
                Button {
                    location = item
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.callout.weight(.medium))
                        Text(item.subtitle)
                            .font(.caption2)
                            .foregroundStyle(location == item ? .white.opacity(0.8) : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(location == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(location == item ? .white : .primary)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(14)
        .frame(width: 200)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            connectionSection
            sessionSection
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var connectionSection: some View {
        switch location {
        case .local:
            VStack(alignment: .leading, spacing: 4) {
                Text("This Mac")
                    .font(.title3.weight(.semibold))
                Text("No connection details are required.")
                    .foregroundStyle(.secondary)
            }
        case .ssh:
            VStack(alignment: .leading, spacing: 10) {
                Text("SSH host")
                    .font(.title3.weight(.semibold))
                HStack {
                    TextField("Host or SSH config alias", text: $sshDraft.host)
                    TextField("Port", text: $sshDraft.port)
                        .frame(width: 80)
                }
                TextField("User", text: $sshDraft.user)
                Toggle("Use remote engine", isOn: $sshDraft.useRemoteEngine)
                Text("Authentication is handled by SSH config, keys, agent, or system prompts. Fantastty does not store credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)
        case .sprite:
            VStack(alignment: .leading, spacing: 10) {
                Text("Sprite")
                    .font(.title3.weight(.semibold))
                TextField("Sprite name", text: $spriteName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Session")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button("Refresh") {
                    refreshDiscovery()
                }
                .disabled(!canDiscover)
            }

            TextField("Filter existing sessions", text: $filter)
                .textFieldStyle(.roundedBorder)

            if isDiscovering {
                ProgressView("Discovering sessions...")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            if let discoveryError {
                Text(discoveryError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            List(rows, selection: $selectedRowID) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                    Text(row.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(row.id)
            }
            .frame(minHeight: 160)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(primaryButtonTitle) {
                guard let action = selectedAction else { return }
                perform(action)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selectedAction == nil || isCreatingSprite)
        }
        .padding(16)
    }

    private var rows: [SessionLauncherRow] {
        SessionLauncherSessionList.rows(
            for: discoveredSessions,
            attachedKeys: sessionManager.attachedTmuxSessionKeys,
            filter: filter
        )
    }

    private var firstExistingRowID: String? {
        rows.dropFirst().first?.id
    }

    private var selectedRow: SessionLauncherRow {
        rows.first(where: { $0.id == selectedRowID }) ?? rows[0]
    }

    private var primaryButtonTitle: String {
        if case .newSession = selectedRow.selection {
            return "Create Workspace"
        }
        return "Adopt Session"
    }

    private var canDiscover: Bool {
        switch location {
        case .local:
            return true
        case .ssh:
            return sshDraft.canDiscover
        case .sprite:
            return SpriteManager.shared.isSpriteCliAvailable
        }
    }

    private var selectedAction: SessionLauncherAction? {
        switch selectedRow.selection {
        case .newSession:
            return SessionLauncherAction.newSessionAction(
                location: location,
                sshHost: sshDraft.sshHostInfo,
                spriteName: spriteName,
                useRemoteEngine: sshDraft.useRemoteEngine
            )
        case .existing(let session):
            switch session {
            case .tmux(let name, let host, _):
                return SessionLauncherAction.existingTmuxAction(
                    name: name,
                    host: host,
                    useRemoteEngine: sshDraft.useRemoteEngine
                )
            case .sprite(let name):
                return .connectSprite(name)
            }
        }
    }

    private func perform(_ action: SessionLauncherAction) {
        switch action {
        case .createSprite(let name):
            isCreatingSprite = true
            SpriteManager.shared.create(name: name) { result in
                isCreatingSprite = false
                switch result {
                case .success(let createdName):
                    sessionManager.performSessionLauncherAction(.connectSprite(createdName))
                    dismiss()
                case .failure(let error):
                    discoveryError = error.localizedDescription
                }
            }
        default:
            sessionManager.performSessionLauncherAction(action)
            dismiss()
        }
    }

    private func refreshDiscovery() {
        discoveryTask?.cancel()
        guard canDiscover else {
            discoveredSessions = []
            return
        }

        isDiscovering = true
        discoveryError = nil
        let location = self.location
        let sshHost = sshDraft.sshHostInfo

        discoveryTask = Task.detached(priority: .userInitiated) {
            var sessions: [SessionLauncherDiscoveredSession] = []
            switch location {
            case .local:
                sessions = TmuxManager.shared.listAllSessions().map {
                    .tmux(name: $0.name, host: .local, windowCount: $0.windowCount)
                }
            case .ssh:
                if let sshHost {
                    sessions = TmuxManager.shared.listRemoteSessions(host: sshHost).map {
                        .tmux(name: $0.name, host: .ssh(sshHost), windowCount: $0.windowCount)
                    }
                }
            case .sprite:
                sessions = SpriteManager.shared.sprites.map { .sprite(name: $0.name) }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                discoveredSessions = sessions
                isDiscovering = false
                if !rows.contains(where: { $0.id == selectedRowID }) {
                    selectedRowID = "new-session"
                }
            }
        }
    }
}
```

- [ ] **Step 3: Run targeted compile and note expected failures**

Run:

```bash
xcodebuild -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/SessionLauncherModelTests test
```

Expected: compile errors identify any remaining references to old sheet booleans or the nested `TmuxAttachSheet.AttachedSessionKey`. Task 4 removes those references.

## Task 4: Wire Entry Points to Unified Launcher

**Files:**
- Modify: `Fantastty/Views/MainWindow.swift`
- Modify: `Fantastty/Views/Sidebar/NewSessionMenu.swift`
- Modify: `Fantastty/Views/Sidebar/SidebarView.swift`
- Modify: `Fantastty/App/AppCommands.swift`
- Modify: `Fantastty/Models/SessionManager.swift`

- [ ] **Step 1: Update `SessionManager.attachedTmuxSessionKeys` to use the shared key**

In `Fantastty/Models/SessionManager.swift`, change the property signature:

```swift
    var attachedTmuxSessionKeys: Set<AttachedSessionKey> {
        var keys = Set<AttachedSessionKey>()
        for session in sessions {
            if case .attached(let info) = session.mode {
                keys.insert(.init(sessionName: info.sessionName, host: info.host))
            }
        }
        return keys
    }
```

- [ ] **Step 2: Present the unified sheet from `MainWindow`**

Replace the three separate sheets in `Fantastty/Views/MainWindow.swift`:

```swift
        .sheet(item: $sessionManager.sessionLauncherRequest) { request in
            SessionLauncherSheet(request: request)
                .environmentObject(sessionManager)
        }
```

- [ ] **Step 3: Route `NewSessionMenu` through the launcher**

Replace `Fantastty/Views/Sidebar/NewSessionMenu.swift` body actions:

```swift
            Button("New Workspace...") {
                sessionManager.showSessionLauncher(.local())
            }

            Button("New Local Workspace") {
                sessionManager.createSession()
            }

            Button("New SSH Workspace...") {
                sessionManager.showSessionLauncher(.ssh())
            }

            Button("New Sprite Workspace...") {
                sessionManager.showSessionLauncher(.sprite())
            }

            Divider()

            Button("Attach to tmux Session...") {
                sessionManager.showSessionLauncher(.local(focus: .existingSessions))
            }
```

- [ ] **Step 4: Route the sidebar footer through the launcher**

In `Fantastty/Views/Sidebar/SidebarView.swift`, replace the bottom `Menu` contents with:

```swift
                    Button("New Workspace...") {
                        sessionManager.showSessionLauncher(.local())
                    }
                    Button("New Local Workspace") {
                        sessionManager.createSession()
                    }
                    Button("New SSH Workspace...") {
                        sessionManager.showSessionLauncher(.ssh())
                    }
                    Button("New Sprite Workspace...") {
                        sessionManager.showSessionLauncher(.sprite())
                    }
                    Divider()
                    Button("Attach to tmux Session...") {
                        sessionManager.showSessionLauncher(.local(focus: .existingSessions))
                    }
```

- [ ] **Step 5: Route app commands through the launcher**

In `Fantastty/App/AppCommands.swift`, update the relevant commands:

```swift
            Button("New Workspace...") {
                sessionManager.showSessionLauncher(.local())
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Local Workspace") {
                sessionManager.createSession()
            }

            Button("New SSH Workspace...") {
                sessionManager.showSessionLauncher(.ssh())
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Button("New Sprite Workspace...") {
                sessionManager.showSessionLauncher(.sprite())
            }
            .keyboardShortcut("k", modifiers: [.command, .option])
```

Add an attach command if it is not already present in the menu group:

```swift
            Button("Attach to tmux Session...") {
                sessionManager.showSessionLauncher(.local(focus: .existingSessions))
            }
```

- [ ] **Step 6: Remove old sheet booleans from `SessionManager`**

Delete these properties once no references remain:

```swift
    @Published var showSSHSheet: Bool = false
    @Published var showSpriteSheet: Bool = false
    @Published var showTmuxAttachSheet: Bool = false
```

- [ ] **Step 7: Verify no old sheet presentation state remains**

Run:

```bash
rg -n "showSSHSheet|showSpriteSheet|showTmuxAttachSheet|SSHConnectionSheet\\(|SpriteConnectionSheet\\(|TmuxAttachSheet\\(" Fantastty FantasttyTests
```

Expected: no matches except references being intentionally migrated in tests before Task 5.

## Task 5: Migrate or Remove Obsolete Sheet Helpers

**Files:**
- Modify or delete: `Fantastty/Views/SSH/SSHConnectionSheet.swift`
- Modify or delete: `Fantastty/Views/Sprite/SpriteConnectionSheet.swift`
- Modify or delete: `Fantastty/Views/Tmux/TmuxAttachSheet.swift`
- Modify: `FantasttyTests/TmuxAttachUITests.swift`
- Test: `FantasttyTests/SessionLauncherModelTests.swift`

- [ ] **Step 1: Move tmux attach helper tests to the launcher model**

For tests that still matter, assert against `SessionLauncherModelTests` helpers. Keep these equivalent checks:

```swift
func testExistingLocalTmuxAlwaysUsesControlModeTransport() {
    let action = SessionLauncherAction.existingTmuxAction(
        name: "local",
        host: .local,
        useRemoteEngine: true
    )

    XCTAssertEqual(action, .attachTmux(TmuxAttachmentInfo(
        sessionName: "local",
        host: .local,
        connectionState: .disconnected(reason: nil),
        launchMode: .attach,
        transport: .tmuxControl
    )))
}
```

Add a discovery mapping helper if the SwiftUI sheet has too much inline discovery code. The helper signature should be:

```swift
enum SessionLauncherDiscovery {
    static func tmuxRows(
        sessions: [TmuxSessionInfo],
        host: TmuxHost
    ) -> [SessionLauncherDiscoveredSession] {
        sessions.map { .tmux(name: $0.name, host: host, windowCount: $0.windowCount) }
    }
}
```

- [ ] **Step 2: Delete obsolete view files only after references are gone**

Run:

```bash
rg -n "SSHConnectionSheet|SpriteConnectionSheet|TmuxAttachSheet" Fantastty FantasttyTests
```

Expected: no matches outside the files being deleted.

Then remove the obsolete sheet files:

```bash
rm Fantastty/Views/SSH/SSHConnectionSheet.swift
rm Fantastty/Views/Sprite/SpriteConnectionSheet.swift
rm Fantastty/Views/Tmux/TmuxAttachSheet.swift
```

Use file deletion only after the `rg` check proves they are unreferenced.

- [ ] **Step 3: Remove or rewrite `TmuxAttachUITests`**

If every assertion moved to `SessionLauncherModelTests`, delete `FantasttyTests/TmuxAttachUITests.swift`. If any helper remains, rename the test file to match the surviving type.

- [ ] **Step 4: Regenerate the Xcode project**

Run:

```bash
xcodegen generate
```

Expected: `Fantastty.xcodeproj/project.pbxproj` updates file references for the new/deleted Swift files.

- [ ] **Step 5: Run targeted model tests**

Run:

```bash
xcodebuild -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/SessionLauncherModelTests test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit unified launcher wiring**

Run:

```bash
git status --short
git add Fantastty/Models/SessionLauncherModel.swift Fantastty/Models/SessionManager.swift Fantastty/Models/TmuxControlMode/TmuxAttachmentInfo.swift Fantastty/Views/SessionLauncher/SessionLauncherSheet.swift Fantastty/Views/MainWindow.swift Fantastty/Views/Sidebar/NewSessionMenu.swift Fantastty/Views/Sidebar/SidebarView.swift Fantastty/App/AppCommands.swift FantasttyTests/SessionLauncherModelTests.swift Fantastty.xcodeproj/project.pbxproj
git add -u Fantastty/Views/SSH/SSHConnectionSheet.swift Fantastty/Views/Sprite/SpriteConnectionSheet.swift Fantastty/Views/Tmux/TmuxAttachSheet.swift FantasttyTests/TmuxAttachUITests.swift
git commit -m "Unify session launcher panels" -m "Replaces separate SSH, Sprite, and tmux attach panels with one location-first New Workspace launcher. The launcher keeps remote engine as an SSH connection checkbox and presents New session as the first row above discovered existing sessions."
```

## Task 6: Polish Behavior and Empty States

**Files:**
- Modify: `Fantastty/Views/SessionLauncher/SessionLauncherSheet.swift`
- Test: `FantasttyTests/SessionLauncherModelTests.swift`

- [ ] **Step 1: Add tests for empty-state row wording through model data**

Add to `SessionLauncherModelTests`:

```swift
func testEmptyExistingSessionsStillShowsNewSessionOnly() {
    let rows = SessionLauncherSessionList.rows(for: [], attachedKeys: [], filter: "")

    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].title, "New session")
}
```

- [ ] **Step 2: Run the test**

Run:

```bash
xcodebuild -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/SessionLauncherModelTests/testEmptyExistingSessionsStillShowsNewSessionOnly test
```

Expected: pass if Task 2 model already supports the behavior.

- [ ] **Step 3: Make the sheet show explicit empty/discovery states**

In `SessionLauncherSheet.sessionSection`, after `List(rows...)`, add a non-list hint below the list:

```swift
            if !isDiscovering && discoveryError == nil && rows.count == 1 {
                Text("No existing sessions found at this location.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

Keep `New session` selectable during loading and errors.

- [ ] **Step 4: Commit polish**

Run:

```bash
git add Fantastty/Views/SessionLauncher/SessionLauncherSheet.swift FantasttyTests/SessionLauncherModelTests.swift
git commit -m "Polish session launcher states" -m "Keeps New session available across empty, loading, and error states and makes the empty existing-session state explicit without adding a second create/adopt control."
```

## Task 7: Final Verification

**Files:**
- All changed files

- [ ] **Step 1: Verify no obsolete panel references remain**

Run:

```bash
rg -n "showSSHSheet|showSpriteSheet|showTmuxAttachSheet|SSHConnectionSheet|SpriteConnectionSheet|TmuxAttachSheet" Fantastty FantasttyTests
```

Expected: no output.

- [ ] **Step 2: Run focused tests**

Run:

```bash
xcodebuild -scheme Fantastty -destination 'platform=macOS' -only-testing:FantasttyTests/SessionLauncherModelTests test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Run the full Xcode suite**

Run:

```bash
xcodebuild -scheme Fantastty -destination 'platform=macOS' test
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Run diff hygiene**

Run:

```bash
git diff --check
```

Expected: no output.

- [ ] **Step 5: Inspect final status**

Run:

```bash
git status --short --branch
```

Expected: branch is `codex/update-session-panel-ux` with no unstaged or untracked production files.

- [ ] **Step 6: Final commit if verification required fixes**

If verification required any fixes, commit them:

```bash
git add <exact files changed by the fix>
git commit -m "Verify session launcher integration" -m "Fixes issues found during focused and full verification of the unified session launcher."
```

If verification did not require fixes, do not create an empty commit.
