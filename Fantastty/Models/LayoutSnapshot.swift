import Foundation

/// Snapshot of the UI layout at quit time, used to restore arrangement on relaunch.
struct LayoutSnapshot: Codable {
    var workspaces: [WorkspaceLayout]
    var selectedWorkspaceID: String?
    var savedAt: Date
}

/// Layout of a single workspace (sidebar item) including its tab order.
struct WorkspaceLayout: Codable {
    var workspaceID: String
    var baseSessionName: String
    var tabSessionNames: [String]   // ordered, excludes base tab
    var selectedTabIndex: Int?       // 0 = base tab
    var sessionType: SessionType?   // nil = .local (backwards compatible)

    enum CodingKeys: String, CodingKey {
        case workspaceID, baseSessionName, tabSessionNames, selectedTabIndex, sessionType
        case stableKey  // legacy, decoded but ignored
    }

    init(workspaceID: String, baseSessionName: String, tabSessionNames: [String],
         selectedTabIndex: Int? = nil, sessionType: SessionType? = nil) {
        self.workspaceID = workspaceID
        self.baseSessionName = baseSessionName
        self.tabSessionNames = tabSessionNames
        self.selectedTabIndex = selectedTabIndex
        self.sessionType = sessionType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceID = try container.decode(String.self, forKey: .workspaceID)
        baseSessionName = try container.decode(String.self, forKey: .baseSessionName)
        tabSessionNames = try container.decode([String].self, forKey: .tabSessionNames)
        selectedTabIndex = try container.decodeIfPresent(Int.self, forKey: .selectedTabIndex)
        sessionType = try container.decodeIfPresent(SessionType.self, forKey: .sessionType)
        // stableKey decoded and ignored for backward compat
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encode(baseSessionName, forKey: .baseSessionName)
        try container.encode(tabSessionNames, forKey: .tabSessionNames)
        try container.encodeIfPresent(selectedTabIndex, forKey: .selectedTabIndex)
        try container.encodeIfPresent(sessionType, forKey: .sessionType)
        // Don't encode stableKey
    }
}
