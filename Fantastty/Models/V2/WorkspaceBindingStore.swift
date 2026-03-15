import Foundation

final class WorkspaceBindingStore {
    private var sessionsByWorkspaceID: [String: Session] = [:]
    private var workspaceIDByClientID: [ObjectIdentifier: String] = [:]

    func bind(session: Session, client: TmuxControlClient) {
        sessionsByWorkspaceID[session.workspaceID] = session
        workspaceIDByClientID[ObjectIdentifier(client)] = session.workspaceID
    }

    func unbind(session: Session) {
        sessionsByWorkspaceID.removeValue(forKey: session.workspaceID)
        if let client = session.controlClient {
            workspaceIDByClientID.removeValue(forKey: ObjectIdentifier(client))
        } else {
            workspaceIDByClientID = workspaceIDByClientID.filter { $0.value != session.workspaceID }
        }
    }

    func session(for workspaceID: String) -> Session? {
        sessionsByWorkspaceID[workspaceID]
    }

    func session(for client: TmuxControlClient) -> Session? {
        guard let workspaceID = workspaceIDByClientID[ObjectIdentifier(client)] else { return nil }
        return sessionsByWorkspaceID[workspaceID]
    }

    func hasBinding(workspaceID: String) -> Bool {
        sessionsByWorkspaceID[workspaceID] != nil
    }

    func clear() {
        sessionsByWorkspaceID.removeAll(keepingCapacity: false)
        workspaceIDByClientID.removeAll(keepingCapacity: false)
    }
}
