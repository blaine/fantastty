import SwiftUI

/// The always-visible header bar for the notes panel.
struct SessionNotesHeader: View {
    @ObservedObject var session: Session
    @Binding var isExpanded: Bool

    var body: some View {
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

            // Keyboard shortcut hint
            Text("⌘.")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .padding(.trailing, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// The expanded notes content panel, shown as an overlay.
struct SessionNotesPanel: View {
    @ObservedObject var session: Session
    @Binding var isExpanded: Bool

    @State private var newNoteText = ""

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
        contentView
            .background(.regularMaterial, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // URL section (ticket, PR)
            urlSection

            // Notes log section
            notesLogSection

            // Add note input
            addNoteSection

            // Tags
            tagsSection
        }
        .padding(12)
    }

    @ViewBuilder
    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            URLFieldRow(icon: "ticket", label: "Ticket", value: Binding(
                get: { session.ticketURL ?? "" },
                set: { session.ticketURL = $0.isEmpty ? nil : $0 }
            ))
            URLFieldRow(icon: "arrow.triangle.pull", label: "PR", value: Binding(
                get: { session.pullRequestURL ?? "" },
                set: { session.pullRequestURL = $0.isEmpty ? nil : $0 }
            ))
        }
        Divider()
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
                                NoteEntryRow(
                                    entry: entry,
                                    dateFormatter: dateFormatter,
                                    fullDateFormatter: fullDateFormatter,
                                    onUpdate: { newContent in
                                        session.updateNote(noteID: entry.id, newContent: newContent)
                                    },
                                    onDelete: {
                                        session.deleteNote(noteID: entry.id)
                                    }
                                )
                                .id(entry.id)
                            }
                        }
                        .textSelection(.enabled)
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
    private var tagsSection: some View {
        if !session.tags.isEmpty {
            Divider()
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

/// A single row in the notes log displaying an editable note entry.
struct NoteEntryRow: View {
    let entry: SessionNoteEntry
    let dateFormatter: DateFormatter
    let fullDateFormatter: DateFormatter
    var onUpdate: ((String) -> Void)?
    var onDelete: (() -> Void)?

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var showRevisions = false
    @FocusState private var textFieldFocused: Bool

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

                // Revision indicator
                if !entry.revisions.isEmpty {
                    Button {
                        showRevisions.toggle()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("\(entry.revisions.count)")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("View \(entry.revisions.count) revision(s)")
                }

                Spacer()

                // Edit and delete buttons on hover
                if isHovered {
                    HStack(spacing: 6) {
                        if onUpdate != nil {
                            Button {
                                startEditing()
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Edit note")
                        }

                        if onDelete != nil {
                            Button {
                                onDelete?()
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption2)
                                    .foregroundColor(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("Delete note")
                        }
                    }
                }
            }

            // Editable content
            if isEditing {
                TextField("Note", text: $editText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($textFieldFocused)
                    .onSubmit {
                        commitEdit()
                    }
                    .onExitCommand {
                        cancelEdit()
                    }
                    .onChange(of: textFieldFocused) { _, focused in
                        if !focused {
                            commitEdit()
                        }
                    }
            } else {
                Text(entry.content)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .onTapGesture(count: 2) {
                        startEditing()
                    }
            }

            // Revision history (collapsible)
            if showRevisions && !entry.revisions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entry.revisions.enumerated().reversed()), id: \.offset) { index, revision in
                        HStack(spacing: 4) {
                            Text(fullDateFormatter.string(from: revision.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                            Text(revision.content)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(.leading, 16)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isEditing ? Color.accentColor.opacity(0.1) : (isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.1) : Color.clear))
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func startEditing() {
        guard onUpdate != nil else { return }
        editText = entry.content
        isEditing = true
        textFieldFocused = true
    }

    private func commitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != entry.content {
            onUpdate?(trimmed)
        }
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
        editText = entry.content
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
                                    NoteEntryRow(
                                        entry: entry,
                                        dateFormatter: dateFormatter,
                                        fullDateFormatter: dateFormatter,
                                        onUpdate: { newContent in
                                            session.updateNote(noteID: entry.id, newContent: newContent)
                                        },
                                        onDelete: {
                                            session.deleteNote(noteID: entry.id)
                                        }
                                    )
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

/// An editable URL field row with an icon, inline text field, and open-link button.
struct URLFieldRow: View {
    let icon: String
    let label: String
    @Binding var value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField(label, text: $value, prompt: Text("No \(label.lowercased())"))
                .font(.caption)
                .textFieldStyle(.plain)
                .lineLimit(1)

            if let url = URL(string: value), !value.isEmpty {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open in browser")
            }
        }
    }
}
