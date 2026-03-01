import Foundation
import Security

// MARK: - Types

enum LinearResource {
    case issue(identifier: String)
    case project(id: String)
}

struct LinearIssue {
    let identifier: String
    let title: String
    let stateName: String
    let assigneeName: String?
    let priorityLabel: String
    let children: [LinearIssue]
}

struct LinearProject {
    let name: String
    let progress: Double
    let targetDate: String?
    let issues: [LinearIssue]
}

enum LinearError: LocalizedError {
    case noKey
    case httpError(Int)
    case decodeError
    case notFound

    var errorDescription: String? {
        switch self {
        case .noKey:          return "No API key configured"
        case .httpError(let c): return "HTTP \(c)"
        case .decodeError:    return "Failed to decode response"
        case .notFound:       return "Not found"
        }
    }
}

// MARK: - Service

class LinearService: ObservableObject {
    static let shared = LinearService()

    @Published var apiKey: String?

    private let keychainService = "com.blainecook.fantastty"
    private let keychainAccount = "linear-api-key"

    private struct CacheEntry { let value: Any; let fetchedAt: Date }
    private var cache: [String: CacheEntry] = [:]
    private static let cacheTTL: TimeInterval = 300

    init() {
        apiKey = loadAPIKey()
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            deleteAPIKey()
            apiKey = nil
        } else {
            saveAPIKey(trimmed)
            apiKey = trimmed
        }
    }

    // MARK: - URL Parsing

    static func parseLinearURL(_ urlString: String) -> LinearResource? {
        if let m = urlString.range(of: #"linear\.app/[^/]+/issue/([A-Z]+-\d+)"#,
                                    options: .regularExpression) {
            let path = String(urlString[m])
            let parts = path.components(separatedBy: "/")
            if let identifier = parts.last(where: { $0.contains("-") && $0.first?.isUppercase == true }) {
                return .issue(identifier: identifier)
            }
        }
        if let m = urlString.range(
                of: #"linear\.app/[^/]+/project/([^/?#]+)"#,
                options: .regularExpression) {
            let matched = String(urlString[m])
            let parts = matched.components(separatedBy: "/")
            if let uuid = parts.last {
                return .project(id: uuid)
            }
        }
        return nil
    }

    // MARK: - URL Helpers

    /// Constructs an issue URL using the team slug from a known Linear base URL.
    static func issueURL(identifier: String, fromBaseURL baseURL: String) -> URL? {
        guard let m = baseURL.range(of: #"https?://linear\.app/[^/]+"#, options: .regularExpression) else { return nil }
        return URL(string: "\(String(baseURL[m]))/issue/\(identifier)")
    }

    // MARK: - Fetch

    func fetchIssue(identifier: String) async throws -> LinearIssue {
        let cacheKey = "issue:\(identifier)"
        if let entry = cache[cacheKey],
           Date().timeIntervalSince(entry.fetchedAt) < Self.cacheTTL,
           let issue = entry.value as? LinearIssue {
            return issue
        }

        guard let key = apiKey, !key.isEmpty else { throw LinearError.noKey }
        _ = key

        let query = """
        { issue(id: "\(identifier)") { identifier title state { name } assignee { name } priorityLabel children { nodes { identifier title state { name } } } } }
        """
        let data = try await graphqlRequest(query: query)

        guard let issueDict = (data["data"] as? [String: Any])?["issue"] as? [String: Any] else {
            throw LinearError.notFound
        }
        guard let issue = decodeIssue(from: issueDict) else {
            throw LinearError.decodeError
        }
        cache[cacheKey] = CacheEntry(value: issue, fetchedAt: Date())
        return issue
    }

    func fetchProject(id: String) async throws -> LinearProject {
        let cacheKey = "project:\(id)"
        if let entry = cache[cacheKey],
           Date().timeIntervalSince(entry.fetchedAt) < Self.cacheTTL,
           let project = entry.value as? LinearProject {
            return project
        }

        guard let key = apiKey, !key.isEmpty else { throw LinearError.noKey }
        _ = key

        let query = """
        { project(id: "\(id)") { name progress targetDate issues(first: 20) { nodes { identifier title state { name } } } } }
        """
        let data = try await graphqlRequest(query: query)

        guard let projectDict = (data["data"] as? [String: Any])?["project"] as? [String: Any] else {
            throw LinearError.notFound
        }
        guard let name = projectDict["name"] as? String else {
            throw LinearError.decodeError
        }
        let progress = projectDict["progress"] as? Double ?? 0.0
        let targetDate = projectDict["targetDate"] as? String
        var issues: [LinearIssue] = []
        if let issuesData = projectDict["issues"] as? [String: Any],
           let nodes = issuesData["nodes"] as? [[String: Any]] {
            issues = nodes.compactMap { decodeIssue(from: $0) }
        }

        let project = LinearProject(name: name, progress: progress, targetDate: targetDate, issues: issues)
        cache[cacheKey] = CacheEntry(value: project, fetchedAt: Date())
        return project
    }

    private func decodeIssue(from dict: [String: Any]) -> LinearIssue? {
        guard let id = dict["identifier"] as? String,
              let title = dict["title"] as? String,
              let stateDict = dict["state"] as? [String: Any],
              let stateName = stateDict["name"] as? String else { return nil }
        let assigneeName = (dict["assignee"] as? [String: Any])?["name"] as? String
        let priorityLabel = dict["priorityLabel"] as? String ?? "No priority"
        var children: [LinearIssue] = []
        if let childrenData = dict["children"] as? [String: Any],
           let nodes = childrenData["nodes"] as? [[String: Any]] {
            children = nodes.compactMap { decodeIssue(from: $0) }
        }
        return LinearIssue(identifier: id, title: title, stateName: stateName,
                           assigneeName: assigneeName, priorityLabel: priorityLabel, children: children)
    }

    // MARK: - GraphQL

    private func graphqlRequest(query: String) async throws -> [String: Any] {
        guard let key = apiKey, !key.isEmpty else { throw LinearError.noKey }

        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["query": query]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw LinearError.httpError(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw LinearError.decodeError
        }
        return json
    }

    // MARK: - Keychain

    private func saveAPIKey(_ key: String) {
        deleteAPIKey()
        guard let data = key.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecValueData: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func loadAPIKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { return nil }
        return key
    }

    private func deleteAPIKey() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
