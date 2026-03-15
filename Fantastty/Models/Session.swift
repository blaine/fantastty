import SwiftUI
import GhosttyKit

/// A workspace in the sidebar, containing one or more terminal tabs.
class Session: ObservableObject, Identifiable, Hashable {
    let id = UUID()

    /// The session type (local or SSH with connection details)
    let type: SessionType

    /// Persistent workspace identity (short UUID prefix, keyed to metadata)
    let workspaceID: String

    /// The default title (from session type), used when no custom name is set.
    private let defaultTitle: String

    /// The displayed title for the sidebar - uses custom name if set, otherwise default.
    var title: String {
        let customName = metadata?.name ?? ""
        return customName.isEmpty ? defaultTitle : customName
    }

    /// The terminal tabs within this session.
    @Published var tabs: [TerminalTab]

    /// The currently selected tab ID.
    @Published var selectedTabID: UUID?

    /// Live cumulative active-focus time (persisted via SessionManager flush)
    @Published var totalActiveSeconds: Double

    /// When this workspace was first created
    var createdAt: Date { metadata?.createdAt ?? Date() }

    /// Workspace attachment mode (attached tmux control is the only supported runtime).
    @Published var mode: SessionMode

    /// Runtime backing availability, separate from workspace ownership.
    @Published var backingState: SessionBackingState = .available

    /// Control mode client for attached tmux sessions.
    var controlClient: TmuxControlClient?

    /// Reference to metadata store for persistence
    private let metadataStore = SessionMetadataStore.shared

    /// Create a new session with explicit tabs and selection state.
    init(title: String, tabs: [TerminalTab], selectedTabID: UUID? = nil, type: SessionType = .local,
         workspaceID: String) {
        self.type = type
        self.workspaceID = workspaceID
        self.defaultTitle = title
        self.tabs = tabs
        self.selectedTabID = selectedTabID ?? tabs.first?.id
        self.mode = .attached(Self.defaultAttachmentInfo(type: type, workspaceID: workspaceID))
        self.totalActiveSeconds = SessionMetadataStore.shared.getOrCreate(forKey: workspaceID).totalActiveSeconds
    }

    /// Create a new session with an initial tab.
    convenience init(title: String, initialTab: TerminalTab, type: SessionType = .local,
                     workspaceID: String) {
        self.init(title: title, tabs: [initialTab], selectedTabID: initialTab.id, type: type,
                  workspaceID: workspaceID)
    }

    /// Create a new empty session with no tabs selected yet.
    convenience init(title: String, type: SessionType = .local, workspaceID: String) {
        self.init(title: title, tabs: [], selectedTabID: nil, type: type, workspaceID: workspaceID)
    }

    /// Convenience initializer for creating a session with a new surface.
    convenience init(type: SessionType, surfaceView: Ghostty.SurfaceView,
                     workspaceID: String) {
        let tab = TerminalTab(type: type, surfaceView: surfaceView)
        self.init(title: type.displayName, initialTab: tab, type: type,
                  workspaceID: workspaceID)
    }

    // MARK: - Metadata Accessors

    /// The session's metadata (persistent, keyed by workspaceID)
    var metadata: SessionMetadata? {
        return metadataStore.getOrCreate(forKey: workspaceID)
    }

    /// Custom name for the workspace (overrides default title)
    var name: String {
        get { metadata?.name ?? "" }
        set {
            metadataStore.update(forKey: workspaceID, name: newValue)
            objectWillChange.send()
        }
    }

    /// All note entries for this workspace (timestamped log)
    var noteEntries: [SessionNoteEntry] {
        metadata?.noteEntries ?? []
    }

    /// Computed property for backwards compatibility - returns all notes joined
    var notes: String {
        metadata?.notes ?? ""
    }

    /// Add a new note entry to this session's log.
    func addNote(content: String, tags: [String] = [], source: NoteSource = .user) {
        metadataStore.appendNote(forKey: workspaceID, content: content, tags: tags, source: source)
        objectWillChange.send()
    }

    /// Update the content of a specific note, saving a revision.
    func updateNote(noteID: UUID, newContent: String) {
        metadataStore.updateNoteContent(forKey: workspaceID, noteID: noteID, newContent: newContent)
        objectWillChange.send()
    }

    /// Delete a specific note.
    func deleteNote(noteID: UUID) {
        metadataStore.deleteNote(forKey: workspaceID, noteID: noteID)
        objectWillChange.send()
    }

    /// Clear all notes for this session.
    func clearNotes() {
        metadataStore.clearNotes(forKey: workspaceID)
        objectWillChange.send()
    }

    /// Whether this workspace needs attention
    var needsAttention: Bool {
        get { metadata?.needsAttention ?? false }
        set {
            metadataStore.update(forKey: workspaceID, needsAttention: newValue)
            objectWillChange.send()
        }
    }

    /// Ticket/task URL for this workspace
    var ticketURL: String? {
        get { metadata?.ticketURL }
        set {
            var meta = metadataStore.getOrCreate(forKey: workspaceID)
            meta.ticketURL = newValue
            metadataStore.update(meta)
            objectWillChange.send()
        }
    }

    /// Pull request URL for this workspace
    var pullRequestURL: String? {
        get { metadata?.pullRequestURL }
        set {
            var meta = metadataStore.getOrCreate(forKey: workspaceID)
            meta.pullRequestURL = newValue
            metadataStore.update(meta)
            objectWillChange.send()
        }
    }

    /// Tags for this workspace
    var tags: [String] {
        get { metadata?.tags ?? [] }
        set {
            metadataStore.update(forKey: workspaceID, tags: newValue)
            objectWillChange.send()
        }
    }

    /// Toggle the attention flag
    func toggleAttention() {
        metadataStore.toggleAttention(forKey: workspaceID)
        objectWillChange.send()
    }

    /// Clear the attention flag
    func clearAttention() {
        metadataStore.clearAttention(forKey: workspaceID)
        objectWillChange.send()
    }

    // MARK: - Tab Management

    /// The currently selected tab, if any.
    var selectedTab: TerminalTab? {
        guard let selectedID = selectedTabID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    /// Add a new tab to this session.
    func addTab(_ tab: TerminalTab) {
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Close a tab by ID. Returns true if the session should be closed (no tabs left).
    @discardableResult
    func closeTab(id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }

        tabs.remove(at: index)

        // If we closed the selected tab, select an adjacent one
        if selectedTabID == id {
            if tabs.isEmpty {
                selectedTabID = nil
            } else {
                let newIndex = min(index, tabs.count - 1)
                selectedTabID = tabs[newIndex].id
            }
        }

        return tabs.isEmpty
    }

    /// Select the next tab (wrapping around).
    func selectNextTab() {
        guard tabs.count > 1, let currentID = selectedTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentID }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabID = tabs[nextIndex].id
    }

    /// Select the previous tab (wrapping around).
    func selectPreviousTab() {
        guard tabs.count > 1, let currentID = selectedTabID,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentID }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
        selectedTabID = tabs[prevIndex].id
    }

    // MARK: - Hashable

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // MARK: - Surface Lookup

    /// Check if any tab in this session contains the given surface view.
    func contains(surfaceView: Ghostty.SurfaceView) -> Bool {
        return tabs.contains { $0.contains(surfaceView: surfaceView) }
    }

    /// Find the tab containing the given surface view.
    func tab(containing surfaceView: Ghostty.SurfaceView) -> TerminalTab? {
        return tabs.first { $0.contains(surfaceView: surfaceView) }
    }

    private static func defaultAttachmentInfo(type: SessionType, workspaceID: String) -> TmuxAttachmentInfo {
        let host: TmuxHost
        switch type {
        case .local, .sprite:
            host = .local
        case .ssh(let hostname, let user, let port):
            host = .ssh(SSHHostInfo(user: user, hostname: hostname, port: port))
        }

        return TmuxAttachmentInfo(
            sessionName: TmuxManager.shared.baseSessionName(workspaceID: workspaceID),
            host: host,
            connectionState: .disconnected(reason: nil),
            launchMode: .create
        )
    }
}
