import SwiftUI

@MainActor
final class NotesService: ObservableObject {
    struct Note: Identifiable, Codable, Equatable {
        var id = UUID()
        var text: String
        var updated: Date

        var title: String {
            let firstLine = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return firstLine.isEmpty ? "New Note" : firstLine
        }
    }

    @Published private(set) var notes: [Note]
    @Published var selectedID: UUID?

    private var saveTask: Task<Void, Never>?

    init() {
        notes = JSONStore.load([Note].self, from: "notes.json") ?? []
        selectedID = notes.first?.id
    }

    var selected: Note? {
        notes.first { $0.id == selectedID }
    }

    func add(text: String = "") {
        let note = Note(text: text, updated: Date())
        notes.insert(note, at: 0)
        selectedID = note.id
        save()
    }

    func updateSelected(_ text: String) {
        guard let index = notes.firstIndex(where: { $0.id == selectedID }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updated = Date()
        scheduleSave()
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        if selectedID == note.id { selectedID = notes.first?.id }
        save()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        JSONStore.save(notes, to: "notes.json")
    }
}

struct NotesTabView: View {
    @EnvironmentObject private var notes: NotesService

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Notes")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    IslandIconButton(symbol: "square.and.pencil", help: "New note") { notes.add() }
                }
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(notes.notes) { note in
                            let selected = note.id == notes.selectedID
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(Format.relative(note.updated))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(selected ? 0.14 : 0.05)))
                            .contentShape(Rectangle())
                            .onTapGesture { notes.selectedID = note.id }
                            .contextMenu {
                                Button("Copy Text") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(note.text, forType: .string)
                                }
                                Button("Delete", role: .destructive) { notes.delete(note) }
                            }
                        }
                    }
                }
            }
            .frame(width: 180)
            .padding(10)
            .cardBackground(cornerRadius: 18, tint: LuminousCardTheme.azure)

            if notes.selected != nil {
                TextEditor(text: Binding(
                    get: { notes.selected?.text ?? "" },
                    set: { notes.updateSelected($0) }
                ))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .cardBackground(cornerRadius: 18, tint: LuminousCardTheme.violet)
            } else {
                VStack(spacing: 10) {
                    EmptyStateView(symbol: "note.text", title: "No notes yet", subtitle: "Jot something down without leaving what you're doing.")
                    PillButton(title: "New Note", symbol: "plus", prominent: true) { notes.add() }
                        .padding(.bottom, 20)
                }
                .cardBackground(cornerRadius: 18, tint: LuminousCardTheme.violet)
            }
        }
    }
}
