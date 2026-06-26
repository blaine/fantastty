import SwiftUI

struct SSHConnectionSheet: View {
    enum ConnectionTarget: Equatable {
        case ssh(SessionType)
        case remoteEngine(SSHHostInfo)
    }

    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = ""
    @State private var user: String = ""
    @State private var port: String = "22"
    @State private var useRemoteEngine = false

    var body: some View {
        VStack(spacing: 16) {
            Text("New SSH Workspace")
                .font(.headline)

            Form {
                TextField("Host:", text: $host)
                    .textFieldStyle(.roundedBorder)

                TextField("User:", text: $user)
                    .textFieldStyle(.roundedBorder)

                TextField("Port:", text: $port)
                    .textFieldStyle(.roundedBorder)

                Toggle("Remote engine", isOn: $useRemoteEngine)
            }
            .padding(.horizontal)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Connect") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 350)
    }

    private func connect() {
        switch Self.connectionTarget(host: host, user: user, port: port, useRemoteEngine: useRemoteEngine) {
        case .ssh(let sessionType):
            sessionManager.createSession(type: sessionType)
        case .remoteEngine(let hostInfo):
            sessionManager.createRemoteEngineSession(host: hostInfo)
        case nil:
            return
        }
        dismiss()
    }

    nonisolated static func connectionTarget(
        host: String,
        user: String,
        port: String,
        useRemoteEngine: Bool
    ) -> ConnectionTarget? {
        guard !host.isEmpty else { return nil }
        let portNum = Int(port)
        let normalizedPort = portNum == 22 ? nil : portNum
        let normalizedUser = user.isEmpty ? nil : user
        if useRemoteEngine {
            return .remoteEngine(SSHHostInfo(user: normalizedUser, hostname: host, port: normalizedPort))
        }
        return .ssh(.ssh(host: host, user: normalizedUser, port: normalizedPort))
    }
}
