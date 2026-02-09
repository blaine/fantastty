import Foundation

/// Source of a session note entry.
enum NoteSource: String, Codable {
    case terminal  // Added via escape sequence from terminal
    case user      // Added manually by user
    case system    // System-generated (e.g., migrated from old notes)
}

/// A revision of a note entry's content (stored when content is edited).
struct NoteRevision: Codable {
    let content: String
    let timestamp: Date

    init(content: String, timestamp: Date = Date()) {
        self.content = content
        self.timestamp = timestamp
    }
}

/// A single timestamped note entry in a session's log.
struct SessionNoteEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    var content: String
    let tags: [String]
    let source: NoteSource
    var revisions: [NoteRevision]

    init(id: UUID = UUID(), timestamp: Date = Date(), content: String, tags: [String] = [], source: NoteSource = .user, revisions: [NoteRevision] = []) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
        self.tags = tags
        self.source = source
        self.revisions = revisions
    }

    /// Update the content, saving the current content as a revision.
    mutating func updateContent(_ newContent: String) {
        guard newContent != content else { return }
        revisions.append(NoteRevision(content: content))
        content = newContent
    }
}

/// Persistent metadata for a session (workspace).
/// Saved to disk and survives app restarts.
/// Keyed by workspaceID for persistence.
struct SessionMetadata: Codable, Identifiable {
    let id: UUID

    /// The workspace ID used for persistence.
    var workspaceID: String

    /// Custom name for the workspace (displayed in sidebar)
    var name: String

    /// Timestamped note entries (replaces old notes: String)
    var noteEntries: [SessionNoteEntry]

    /// Computed property for backwards compatibility
    var notes: String {
        get {
            noteEntries.map { $0.content }.joined(separator: "\n")
        }
        set {
            // When setting notes directly, create a user entry
            if !newValue.isEmpty {
                noteEntries.append(SessionNoteEntry(content: newValue, source: .user))
            }
        }
    }

    /// Whether this workspace needs attention (manual toggle or auto-detected)
    var needsAttention: Bool

    /// Timestamp when attention was last flagged
    var attentionFlaggedAt: Date?

    /// Tags for organization
    var tags: [String]

    /// Whether this workspace is archived (hidden from active sidebar, tmux killed)
    var isArchived: Bool

    /// When the workspace was archived
    var archivedAt: Date?

    /// Ticket/task URL associated with this workspace
    var ticketURL: String?

    /// Pull request URL associated with this workspace
    var pullRequestURL: String?

    /// Creation date
    var createdAt: Date

    /// Last modified date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        workspaceID: String = "",
        name: String = "",
        noteEntries: [SessionNoteEntry] = [],
        needsAttention: Bool = false,
        tags: [String] = [],
        isArchived: Bool = false,
        archivedAt: Date? = nil,
        ticketURL: String? = nil,
        pullRequestURL: String? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.name = name
        self.noteEntries = noteEntries
        self.needsAttention = needsAttention
        self.attentionFlaggedAt = nil
        self.tags = tags
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.ticketURL = ticketURL
        self.pullRequestURL = pullRequestURL
        self.createdAt = Date()
        self.modifiedAt = Date()
    }

    /// Append a new note entry to the session's log.
    mutating func appendNote(content: String, tags: [String] = [], source: NoteSource = .terminal) {
        let entry = SessionNoteEntry(content: content, tags: tags, source: source)
        noteEntries.append(entry)
        modifiedAt = Date()
    }

    // MARK: - Codable with Migration Support

    enum CodingKeys: String, CodingKey {
        case id, workspaceID, name, noteEntries
        case needsAttention, attentionFlaggedAt, tags, createdAt, modifiedAt
        case isArchived, archivedAt, ticketURL, pullRequestURL
        // Legacy keys for migration
        case stableKey, notes, description, basePath, remoteHost
        case tmuxSessionName, tmuxTabSessions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)

        // Try new workspaceID first, fall back to legacy stableKey
        if let wsID = try container.decodeIfPresent(String.self, forKey: .workspaceID) {
            workspaceID = wsID
        } else {
            workspaceID = try container.decodeIfPresent(String.self, forKey: .stableKey) ?? ""
        }

        // Try new 'name' key first, fall back to legacy 'description'
        if let nameValue = try container.decodeIfPresent(String.self, forKey: .name) {
            name = nameValue
        } else {
            name = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        }

        needsAttention = try container.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false
        attentionFlaggedAt = try container.decodeIfPresent(Date.self, forKey: .attentionFlaggedAt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        ticketURL = try container.decodeIfPresent(String.self, forKey: .ticketURL)
        pullRequestURL = try container.decodeIfPresent(String.self, forKey: .pullRequestURL)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()

        // Try to decode new noteEntries format first
        if let entries = try container.decodeIfPresent([SessionNoteEntry].self, forKey: .noteEntries) {
            noteEntries = entries
        } else if let legacyNotes = try container.decodeIfPresent(String.self, forKey: .notes), !legacyNotes.isEmpty {
            // Migrate legacy notes string to a single system entry
            noteEntries = [SessionNoteEntry(content: legacyNotes, source: .system)]
        } else {
            noteEntries = []
        }

        // Ignore legacy keys (basePath, remoteHost, tmuxSessionName, tmuxTabSessions)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(name, forKey: .name)
        try container.encode(noteEntries, forKey: .noteEntries)
        try container.encode(needsAttention, forKey: .needsAttention)
        try container.encodeIfPresent(attentionFlaggedAt, forKey: .attentionFlaggedAt)
        try container.encode(tags, forKey: .tags)
        try container.encode(isArchived, forKey: .isArchived)
        try container.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try container.encodeIfPresent(ticketURL, forKey: .ticketURL)
        try container.encodeIfPresent(pullRequestURL, forKey: .pullRequestURL)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        // Don't encode legacy keys
    }
}

/// Manages persistence of session metadata to disk.
/// Metadata is keyed by workspaceID for persistence across sessions.
class SessionMetadataStore: ObservableObject {
    static let shared = SessionMetadataStore()

    /// Metadata keyed by workspaceID
    @Published private(set) var metadata: [String: SessionMetadata] = [:]

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        // Store in ~/.fantastty/workspaces.json
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let fantasttyDir = homeDir.appendingPathComponent(".fantastty")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: fantasttyDir, withIntermediateDirectories: true)

        self.fileURL = fantasttyDir.appendingPathComponent("workspaces.json")

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    // MARK: - WorkspaceID-Based Access

    /// Get or create metadata for a workspace ID.
    func getOrCreate(forKey key: String) -> SessionMetadata {
        if let existing = metadata[key] {
            return existing
        }
        let new = SessionMetadata(id: UUID(), workspaceID: key)
        metadata[key] = new
        save()
        return new
    }

    /// Update metadata.
    func update(_ meta: SessionMetadata) {
        let key = meta.workspaceID
        guard !key.isEmpty else { return }
        var updated = meta
        updated.modifiedAt = Date()
        metadata[key] = updated
        save()
    }

    /// Update specific fields for a workspace ID.
    func update(
        forKey key: String,
        name: String? = nil,
        needsAttention: Bool? = nil,
        tags: [String]? = nil,
        isArchived: Bool? = nil,
        ticketURL: String? = nil,
        pullRequestURL: String? = nil
    ) {
        var meta = getOrCreate(forKey: key)

        if let name = name {
            meta.name = name
        }
        if let needsAttention = needsAttention {
            meta.needsAttention = needsAttention
            if needsAttention {
                meta.attentionFlaggedAt = Date()
            } else {
                meta.attentionFlaggedAt = nil
            }
        }
        if let tags = tags {
            meta.tags = tags
        }
        if let isArchived = isArchived {
            meta.isArchived = isArchived
            meta.archivedAt = isArchived ? Date() : nil
        }
        if let ticketURL = ticketURL {
            meta.ticketURL = ticketURL
        }
        if let pullRequestURL = pullRequestURL {
            meta.pullRequestURL = pullRequestURL
        }

        update(meta)
    }

    /// All archived workspace metadata, sorted by archivedAt descending.
    var archivedWorkspaces: [SessionMetadata] {
        metadata.values
            .filter { $0.isArchived }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// Append a note entry to a workspace's log.
    func appendNote(forKey key: String, content: String, tags: [String] = [], source: NoteSource = .terminal) {
        var meta = getOrCreate(forKey: key)
        meta.appendNote(content: content, tags: tags, source: source)
        update(meta)
    }

    /// Get note entries for a workspace.
    func noteEntries(forKey key: String) -> [SessionNoteEntry] {
        return getOrCreate(forKey: key).noteEntries
    }

    /// Update the content of a specific note entry, saving a revision.
    func updateNoteContent(forKey key: String, noteID: UUID, newContent: String) {
        var meta = getOrCreate(forKey: key)
        if let index = meta.noteEntries.firstIndex(where: { $0.id == noteID }) {
            meta.noteEntries[index].updateContent(newContent)
            update(meta)
        }
    }

    /// Delete a specific note entry.
    func deleteNote(forKey key: String, noteID: UUID) {
        var meta = getOrCreate(forKey: key)
        meta.noteEntries.removeAll { $0.id == noteID }
        update(meta)
    }

    /// Clear all note entries for a workspace.
    func clearNotes(forKey key: String) {
        var meta = getOrCreate(forKey: key)
        meta.noteEntries = []
        update(meta)
    }

    /// Toggle attention flag for a workspace.
    func toggleAttention(forKey key: String) {
        var meta = getOrCreate(forKey: key)
        meta.needsAttention = !meta.needsAttention
        meta.attentionFlaggedAt = meta.needsAttention ? Date() : nil
        update(meta)
    }

    /// Clear attention flag for a workspace.
    func clearAttention(forKey key: String) {
        update(forKey: key, needsAttention: false)
    }

    /// Remove metadata for a workspace.
    func remove(forKey key: String) {
        metadata.removeValue(forKey: key)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let array = try decoder.decode([SessionMetadata].self, from: data)
            metadata = Dictionary(uniqueKeysWithValues: array.compactMap { meta -> (String, SessionMetadata)? in
                let key = meta.workspaceID
                guard !key.isEmpty else { return nil }
                return (key, meta)
            })
        } catch {
            print("Failed to load session metadata: \(error)")
        }
    }

    private func save() {
        do {
            let array = Array(metadata.values)
            let data = try encoder.encode(array)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save session metadata: \(error)")
        }
    }
}
