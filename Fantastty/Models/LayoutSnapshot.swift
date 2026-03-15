import Foundation

/// Snapshot of the UI layout at quit time, used to restore arrangement on relaunch.
struct LayoutSnapshot: Codable {
    static let attachedOnlySchemaVersion = 1

    var schemaVersion: Int
    var workspaces: [WorkspaceLayout]
    var selectedWorkspaceID: String?
    var savedAt: Date

    enum CodingKeys: String, CodingKey {
        case schemaVersion, workspaces, selectedWorkspaceID, savedAt
    }

    init(
        schemaVersion: Int = Self.attachedOnlySchemaVersion,
        workspaces: [WorkspaceLayout],
        selectedWorkspaceID: String?,
        savedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
        self.savedAt = savedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        workspaces = try container.decode([WorkspaceLayout].self, forKey: .workspaces)
        selectedWorkspaceID = try container.decodeIfPresent(String.self, forKey: .selectedWorkspaceID)
        savedAt = try container.decode(Date.self, forKey: .savedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encodeIfPresent(selectedWorkspaceID, forKey: .selectedWorkspaceID)
        try container.encode(savedAt, forKey: .savedAt)
    }
}

enum WorkspaceTabKind: String, Codable, Equatable {
    case terminal
    case browser
}

struct WorkspaceTabLayout: Codable, Equatable {
    var kind: WorkspaceTabKind
    var url: URL?

    init(kind: WorkspaceTabKind, url: URL? = nil) {
        self.kind = kind
        self.url = url
    }
}

/// Layout of a single workspace (sidebar item) including its tab order.
struct WorkspaceLayout: Codable {
    var workspaceID: String
    var tabs: [WorkspaceTabLayout]
    var selectedTabIndex: Int?
    var sessionType: SessionType?
    var attachment: TmuxAttachmentInfo?

    enum CodingKeys: String, CodingKey {
        case workspaceID, tabs, selectedTabIndex, sessionType, attachment
    }

    init(
        workspaceID: String,
        selectedTabIndex: Int? = nil,
        sessionType: SessionType? = nil,
        attachment: TmuxAttachmentInfo? = nil,
        tabs: [WorkspaceTabLayout] = []
    ) {
        self.workspaceID = workspaceID
        self.tabs = tabs
        self.selectedTabIndex = selectedTabIndex
        self.sessionType = sessionType
        self.attachment = attachment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        tabs = try container.decodeIfPresent([WorkspaceTabLayout].self, forKey: .tabs) ?? []
        selectedTabIndex = try container.decodeIfPresent(Int.self, forKey: .selectedTabIndex)
        sessionType = try container.decodeIfPresent(SessionType.self, forKey: .sessionType)
        attachment = try container.decodeIfPresent(TmuxAttachmentInfo.self, forKey: .attachment)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(selectedTabIndex, forKey: .selectedTabIndex)
        try container.encodeIfPresent(sessionType, forKey: .sessionType)
        try container.encodeIfPresent(attachment, forKey: .attachment)
    }
}
