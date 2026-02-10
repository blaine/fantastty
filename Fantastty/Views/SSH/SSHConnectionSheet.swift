import SwiftUI

struct SSHConnectionSheet: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = ""
    @State private var user: String = ""
    @State private var port: String = "22"

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
        let portNum = Int(port)
        let sessionType: SessionType = .ssh(
            host: host,
            user: user.isEmpty ? nil : user,
            port: portNum == 22 ? nil : portNum
        )
        sessionManager.createSession(type: sessionType)
        dismiss()
    }
}
