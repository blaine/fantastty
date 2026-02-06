import SwiftUI

/// A collapsible panel showing session notes as a timestamped log stream.
struct SessionNotesPanel: View {
    @ObservedObject var session: Session
    @Binding var isExpanded: Bool

    @State private var editingName = false
    @State private var draftName = ""
    @State private var newNoteText = ""
    @State private var scrollToBottom = false

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Header bar (always visible)
            headerBar

            // Expandable content
            if isExpanded {
                Divider()
                contentView
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var headerBar: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Image(systemName: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !session.noteEntries.isEmpty {
                        Text("\(session.noteEntries.count)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if !session.name.isEmpty && !isExpanded {
                Text(session.name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Name section
            nameSection

            Divider()

            // Notes log section
            notesLogSection

            // Add note input
            addNoteSection

            // Metadata
            metadataSection
        }
        .padding(12)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Name")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(editingName ? "Done" : "Edit") {
                    if editingName {
                        session.name = draftName
                    } else {
                        draftName = session.name
                    }
                    editingName.toggle()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }

            if editingName {
                TextField("Custom workspace name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit {
                        session.name = draftName
                        editingName = false
                    }
            } else {
                Text(session.name.isEmpty ? session.title : session.name)
                    .font(.callout)
                    .foregroundStyle(session.name.isEmpty ? .tertiary : .primary)
            }
        }
    }

    private var notesLogSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Notes Log")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                if !session.noteEntries.isEmpty {
                    Button("Clear") {
                        session.clearNotes()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.red.opacity(0.8))
                }
            }

            if session.noteEntries.isEmpty {
                Text("No notes yet")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(session.noteEntries) { entry in
                                NoteEntryRow(entry: entry, dateFormatter: dateFormatter, fullDateFormatter: fullDateFormatter)
                                    .id(entry.id)
                            }
                        }
                    }
                    .frame(minHeight: 60, maxHeight: 200)
                    .onChange(of: session.noteEntries.count) {
                        // Auto-scroll to bottom when new entries are added
                        if let lastEntry = session.noteEntries.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(lastEntry.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var addNoteSection: some View {
        HStack(spacing: 8) {
            TextField("Add a note...", text: $newNoteText)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .onSubmit {
                    addNote()
                }

            Button {
                addNote()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func addNote() {
        let content = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        session.addNote(content: content, source: .user)
        newNoteText = ""
    }

    @ViewBuilder
    private var metadataSection: some View {
        if let basePath = session.basePath, !basePath.isEmpty {
            Divider()
            HStack {
                Text("Path:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(basePath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }

        if !session.tags.isEmpty {
            HStack {
                Text("Tags:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(session.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
    }
}

/// A single row in the notes log displaying a note entry.
struct NoteEntryRow: View {
    let entry: SessionNoteEntry
    let dateFormatter: DateFormatter
    let fullDateFormatter: DateFormatter

    @State private var isHovered = false

    private var sourceIcon: String {
        switch entry.source {
        case .terminal: return "terminal"
        case .user: return "person"
        case .system: return "gear"
        }
    }

    private var sourceColor: Color {
        switch entry.source {
        case .terminal: return .green
        case .user: return .blue
        case .system: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: sourceIcon)
                    .font(.caption2)
                    .foregroundColor(sourceColor.opacity(0.8))

                Text(isHovered ? fullDateFormatter.string(from: entry.timestamp) : dateFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                if !entry.tags.isEmpty {
                    ForEach(entry.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .foregroundColor(.accentColor.opacity(0.7))
                    }
                }
            }

            Text(entry.content)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.1) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Floating notes popover for quick access
struct SessionNotesPopover: View {
    @ObservedObject var session: Session
    @Environment(\.dismiss) var dismiss

    @State private var draftName = ""
    @State private var newNoteText = ""

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Workspace Notes")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Custom workspace name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
            }

            // Notes Log
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(session.noteEntries.count) entries")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if session.noteEntries.isEmpty {
                    Text("No notes yet")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(session.noteEntries) { entry in
                                    NoteEntryRow(entry: entry, dateFormatter: dateFormatter, fullDateFormatter: dateFormatter)
                                        .id(entry.id)
                                }
                            }
                        }
                        .frame(minHeight: 100, maxHeight: 200)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .onAppear {
                            if let lastEntry = session.noteEntries.last {
                                proxy.scrollTo(lastEntry.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            // Add note input
            HStack(spacing: 8) {
                TextField("Add a note...", text: $newNoteText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addNote()
                    }

                Button {
                    addNote()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Save button
            HStack {
                Spacer()
                Button("Save") {
                    session.name = draftName
                    dismiss()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 400, height: 400)
        .onAppear {
            draftName = session.name
        }
    }

    private func addNote() {
        let content = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        session.addNote(content: content, source: .user)
        newNoteText = ""
    }
}
