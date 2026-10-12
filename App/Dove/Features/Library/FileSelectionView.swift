import DoveKit
import SwiftUI

/// Picks the files of a torrent the service is waiting on (Real-Debrid's `waiting_files_selection`).
/// Videos without samples are checked to start with.
struct FileSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    let backend: any FileSelecting
    let itemID: LibraryItem.ID
    /// Called after the service accepted the selection.
    let onSelected: () async -> Void

    @State private var selection: FileSelection?
    @State private var chosen: Set<LibraryFile.ID> = []
    @State private var message: String?
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                if let selection {
                    Section {
                        ForEach(selection.files) { file in
                            Button {
                                toggle(file.id)
                            } label: {
                                row(file)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("\(chosen.count) of \(selection.files.count) files")
                            Spacer()
                            Button(chosen.count == selection.files.count ? "None" : "All") {
                                chosen = chosen.count == selection.files.count ? [] : Set(selection.files.map(\.id))
                            }
                            .font(.caption)
                        }
                    }
                }
            }
            .overlay {
                if selection == nil && message == nil { ProgressView() }
            }
            .navigationTitle("Choose files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Start") { Task { await send() } }
                            .disabled(chosen.isEmpty)
                    }
                }
            }
            .task { await load() }
        }
    }

    private func row(_ file: LibraryFile) -> some View {
        HStack {
            Image(systemName: chosen.contains(file.id) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(chosen.contains(file.id) ? Color.accentColor : .secondary)
            VStack(alignment: .leading) {
                Text(file.name).font(.subheadline)
                if let size = file.size {
                    Text(size.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func toggle(_ id: LibraryFile.ID) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    private func load() async {
        do {
            let loaded = try await backend.selectableFiles(itemID)
            selection = loaded
            chosen = loaded.suggested
        } catch {
            message = error.localizedDescription
        }
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        do {
            try await backend.selectFiles(itemID, fileIDs: chosen)
            await onSelected()
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
