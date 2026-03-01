import SwiftUI

struct SpriteConnectionSheet: View {
    @EnvironmentObject var sessionManager: SessionManager
    @ObservedObject private var spriteManager = SpriteManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var spriteName: String = ""
    @State private var isCreating: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("New Sprite Workspace")
                .font(.headline)

            if spriteManager.isSpriteCliAvailable {
                spriteForm
            } else {
                cliNotFoundView
            }

            buttonBar
        }
        .padding()
        .frame(width: 380)
        .overlay {
            if isCreating {
                creatingOverlay
            }
        }
        .onAppear {
            spriteManager.refreshList()
        }
    }

    // MARK: - Subviews

    private var cliNotFoundView: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("sprite CLI not found")
                .font(.subheadline)
                .fontWeight(.medium)
            Text("Install the Fly.io Sprites CLI to use this feature.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var spriteForm: some View {
        VStack(spacing: 12) {
            TextField("Sprite name:", text: $spriteName)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            spriteListSection

            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var spriteListSection: some View {
        if spriteManager.isLoading {
            ProgressView("Loading sprites...")
                .frame(height: 120)
        } else if spriteManager.sprites.isEmpty {
            Text("No sprites found")
                .foregroundStyle(.secondary)
                .frame(height: 120)
        } else {
            spriteListView
        }
    }

    private var spriteListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(spriteManager.sprites, id: \.name) { sprite in
                    spriteRow(sprite)
                }
            }
        }
        .frame(height: 160)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
    }

    private func spriteRow(_ sprite: SpriteInfo) -> some View {
        Button {
            spriteName = sprite.name
        } label: {
            HStack {
                Image(systemName: "cloud")
                    .foregroundStyle(.secondary)
                Text(sprite.name)
                Spacer()
                if sprite.name == spriteName {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(sprite.name == spriteName ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    private var buttonBar: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if spriteManager.isSpriteCliAvailable {
                Button("Create & Connect") {
                    createAndConnect()
                }
                .disabled(spriteName.isEmpty || isCreating)

                Button("Connect") {
                    connect(spriteName: spriteName)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(spriteName.isEmpty || isCreating)
            }
        }
        .padding(.horizontal)
    }

    private var creatingOverlay: some View {
        ZStack {
            Color.black.opacity(0.1)
            ProgressView("Creating sprite...")
        }
    }

    // MARK: - Actions

    private func connect(spriteName: String) {
        let sessionType: SessionType = .sprite(name: spriteName)
        sessionManager.createSession(type: sessionType)
        dismiss()
    }

    private func createAndConnect() {
        isCreating = true
        errorMessage = nil
        let nameToCreate = spriteName

        SpriteManager.shared.create(name: nameToCreate) { result in
            isCreating = false
            switch result {
            case .success(let createdName):
                connect(spriteName: createdName)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }
}
