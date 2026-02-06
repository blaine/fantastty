import Foundation

/// Source of a session note entry.
enum NoteSource: String, Codable {
    case terminal  // Added via escape sequence from terminal
    case user      // Added manually by user
    case system    // System-generated (e.g., migrated from old notes)
}

/// A single timestamped note entry in a session's log.
struct SessionNoteEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let content: String
    let tags: [String]
    let source: NoteSource

    init(id: UUID = UUID(), timestamp: Date = Date(), content: String, tags: [String] = [], source: NoteSource = .user) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
        self.tags = tags
        self.source = source
    }
}

/// Persistent metadata for a session (workspace).
/// Saved to disk and survives app restarts.
struct SessionMetadata: Codable, Identifiable {
    let id: UUID

    /// Custom name for the workspace (displayed in sidebar)
    var name: String

    /// Timestamped note entries (replaces old notes: String)
    var noteEntries: [SessionNoteEntry]

    /// Legacy notes field - only used during migration, not persisted
    private var _legacyNotes: String?

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

    /// Base path associated with this workspace (for local sessions)
    var basePath: String?

    /// Remote host (for SSH sessions)
    var remoteHost: String?

    /// Whether this workspace needs attention (manual toggle or auto-detected)
    var needsAttention: Bool

    /// Timestamp when attention was last flagged
    var attentionFlaggedAt: Date?

    /// Tags for organization
    var tags: [String]

    /// Creation date
    var createdAt: Date

    /// Last modified date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        noteEntries: [SessionNoteEntry] = [],
        basePath: String? = nil,
        remoteHost: String? = nil,
        needsAttention: Bool = false,
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.noteEntries = noteEntries
        self.basePath = basePath
        self.remoteHost = remoteHost
        self.needsAttention = needsAttention
        self.attentionFlaggedAt = nil
        self.tags = tags
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
        case id, name, noteEntries, basePath, remoteHost
        case needsAttention, attentionFlaggedAt, tags, createdAt, modifiedAt
        // Legacy keys for migration
        case notes, description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        // Try new 'name' key first, fall back to legacy 'description'
        if let nameValue = try container.decodeIfPresent(String.self, forKey: .name) {
            name = nameValue
        } else {
            name = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        }
        basePath = try container.decodeIfPresent(String.self, forKey: .basePath)
        remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost)
        needsAttention = try container.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false
        attentionFlaggedAt = try container.decodeIfPresent(Date.self, forKey: .attentionFlaggedAt)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(noteEntries, forKey: .noteEntries)
        try container.encodeIfPresent(basePath, forKey: .basePath)
        try container.encodeIfPresent(remoteHost, forKey: .remoteHost)
        try container.encode(needsAttention, forKey: .needsAttention)
        try container.encodeIfPresent(attentionFlaggedAt, forKey: .attentionFlaggedAt)
        try container.encode(tags, forKey: .tags)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        // Don't encode legacy keys
    }
}

/// Manages persistence of session metadata to disk.
class SessionMetadataStore: ObservableObject {
    static let shared = SessionMetadataStore()

    @Published private(set) var metadata: [UUID: SessionMetadata] = [:]

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        // Store in ~/.fantastty/sessions.json
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let mickeyTermDir = homeDir.appendingPathComponent(".fantastty")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: mickeyTermDir, withIntermediateDirectories: true)

        self.fileURL = mickeyTermDir.appendingPathComponent("sessions.json")

        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    /// Get or create metadata for a session ID.
    func getOrCreate(for sessionID: UUID) -> SessionMetadata {
        if let existing = metadata[sessionID] {
            return existing
        }
        let new = SessionMetadata(id: sessionID)
        metadata[sessionID] = new
        save()
        return new
    }

    /// Update metadata for a session.
    func update(_ meta: SessionMetadata) {
        var updated = meta
        updated.modifiedAt = Date()
        metadata[meta.id] = updated
        save()
    }

    /// Update specific fields for a session.
    func update(
        sessionID: UUID,
        name: String? = nil,
        basePath: String? = nil,
        needsAttention: Bool? = nil,
        tags: [String]? = nil
    ) {
        var meta = getOrCreate(for: sessionID)

        if let name = name {
            meta.name = name
        }
        if let basePath = basePath {
            meta.basePath = basePath
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

        update(meta)
    }

    /// Append a note entry to a session's log.
    func appendNote(sessionID: UUID, content: String, tags: [String] = [], source: NoteSource = .terminal) {
        var meta = getOrCreate(for: sessionID)
        meta.appendNote(content: content, tags: tags, source: source)
        update(meta)
    }

    /// Get note entries for a session.
    func noteEntries(for sessionID: UUID) -> [SessionNoteEntry] {
        return getOrCreate(for: sessionID).noteEntries
    }

    /// Clear all note entries for a session.
    func clearNotes(sessionID: UUID) {
        var meta = getOrCreate(for: sessionID)
        meta.noteEntries = []
        update(meta)
    }

    /// Toggle attention flag for a session.
    func toggleAttention(sessionID: UUID) {
        var meta = getOrCreate(for: sessionID)
        meta.needsAttention = !meta.needsAttention
        meta.attentionFlaggedAt = meta.needsAttention ? Date() : nil
        update(meta)
    }

    /// Clear attention flag for a session.
    func clearAttention(sessionID: UUID) {
        update(sessionID: sessionID, needsAttention: false)
    }

    /// Remove metadata for a deleted session.
    func remove(sessionID: UUID) {
        metadata.removeValue(forKey: sessionID)
        save()
    }

    /// Get all sessions that need attention.
    var sessionsNeedingAttention: [SessionMetadata] {
        metadata.values.filter { $0.needsAttention }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let array = try decoder.decode([SessionMetadata].self, from: data)
            metadata = Dictionary(uniqueKeysWithValues: array.map { ($0.id, $0) })
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

    /// Export notes for a session to a standalone file (for Claude access).
    func exportNotes(sessionID: UUID, to url: URL) throws {
        guard let meta = metadata[sessionID] else { return }

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .short
        dateFormatter.timeStyle = .medium

        var notesContent = ""
        for entry in meta.noteEntries {
            let timestamp = dateFormatter.string(from: entry.timestamp)
            let sourceTag = "[\(entry.source.rawValue)]"
            let tagsStr = entry.tags.isEmpty ? "" : " #\(entry.tags.joined(separator: " #"))"
            notesContent += "\(timestamp) \(sourceTag)\(tagsStr)\n\(entry.content)\n\n"
        }

        let content = """
        # \(meta.name.isEmpty ? "Session Notes" : meta.name)

        Session ID: \(sessionID)
        Created: \(meta.createdAt)
        Modified: \(meta.modifiedAt)
        Base Path: \(meta.basePath ?? "N/A")
        Tags: \(meta.tags.joined(separator: ", "))

        ---

        \(notesContent)
        """

        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
