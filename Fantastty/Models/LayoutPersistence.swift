import Foundation
import os

/// Encapsulates reading and writing the layout snapshot file.
///
/// SessionManager delegates all layout I/O here so the logic can be
/// tested without a running SessionManager instance.
final class LayoutPersistence {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.blainecook.fantastty",
        category: "layout-persistence"
    )

    private let layoutURL: URL

    init(layoutURL: URL? = nil) {
        if let layoutURL {
            self.layoutURL = layoutURL
        } else {
            let homeDir = FileManager.default.homeDirectoryForCurrentUser
            self.layoutURL = homeDir.appendingPathComponent(".fantastty/layout.json")
        }
    }

    // MARK: - Snapshot Building

    /// Build a LayoutSnapshot from the current set of sessions.
    ///
    /// Only sessions in `.attached` mode are included.  Within each session only
    /// browser tabs are persisted; terminal tabs are omitted (tmux recreates them
    /// on reconnect).
    func buildSnapshot(sessions: [Session], selectedWorkspaceID: String?) -> LayoutSnapshot {
        var workspaces: [WorkspaceLayout] = []

        for session in sessions {
            guard case .attached(let info) = session.mode else {
                Self.logger.error(
                    "Skipping non-attached session during buildSnapshot: \(session.workspaceID, privacy: .public)"
                )
                continue
            }

            let browserTabs = session.tabs.compactMap { tab -> WorkspaceTabLayout? in
                guard tab.kind == .browser else { return nil }
                return WorkspaceTabLayout(kind: .browser, url: tab.url)
            }

            let selectedBrowserIndex: Int?
            if let selectedID = session.selectedTabID,
               let selectedIndex = session.tabs.firstIndex(where: { $0.id == selectedID }),
               session.tabs[selectedIndex].kind == .browser {
                selectedBrowserIndex = session.tabs[..<selectedIndex]
                    .filter { $0.kind == .browser }
                    .count
            } else {
                selectedBrowserIndex = nil
            }

            workspaces.append(WorkspaceLayout(
                workspaceID: session.workspaceID,
                selectedTabIndex: selectedBrowserIndex,
                sessionType: session.type == .local ? nil : session.type,
                attachment: persistedAttachmentInfo(from: info),
                tabs: browserTabs
            ))
        }

        return LayoutSnapshot(
            workspaces: workspaces,
            selectedWorkspaceID: selectedWorkspaceID,
            savedAt: Date()
        )
    }

    // MARK: - Save / Load / Delete

    /// Encode `snapshot` to JSON and write it atomically to disk.
    func save(_ snapshot: LayoutSnapshot) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            try data.write(to: layoutURL, options: .atomic)
            Self.logger.info(
                "Saved layout snapshot with \(snapshot.workspaces.count) workspaces"
            )
        } catch {
            Self.logger.error("Failed to save layout: \(error)")
        }
    }

    /// Load a LayoutSnapshot from disk.  Returns `nil` if the file is missing or corrupt.
    func load() -> LayoutSnapshot? {
        guard FileManager.default.fileExists(atPath: layoutURL.path) else { return nil }

        do {
            let data = try Data(contentsOf: layoutURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LayoutSnapshot.self, from: data)
        } catch {
            Self.logger.warning("Failed to load layout snapshot: \(error)")
            return nil
        }
    }

    /// Remove the layout file from disk.
    func delete() {
        try? FileManager.default.removeItem(at: layoutURL)
    }

    // MARK: - Private helpers

    private func persistedAttachmentInfo(from info: TmuxAttachmentInfo) -> TmuxAttachmentInfo {
        var persisted = info
        persisted.connectionState = .disconnected(reason: nil)
        persisted.launchMode = .attach
        return persisted
    }
}
