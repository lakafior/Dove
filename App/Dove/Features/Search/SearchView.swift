import DoveKit
import SwiftUI

/// Stage 1: the smart field accepts magnets, info hashes, .torrent/.nzb URLs and hoster links.
/// Stage 2 adds title search (TMDB) and the source list sheet.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var pendingSource: Source?
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title, magnet or link", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(handleSubmit)
                } footer: {
                    if let message { Text(message) }
                }
            }
            .navigationTitle("Dove")
            .sheet(item: $pendingSource) { source in
                AddSourceSheet(source: source) { result in
                    pendingSource = nil
                    message = result
                    if result.hasPrefix("Added") { text = "" }
                }
            }
        }
    }

    private func handleSubmit() {
        if let source = SourceDetector.detect(text) {
            pendingSource = source
        } else {
            message = "Title search arrives in stage 2."
        }
    }
}

/// Lets the user confirm which compatible backend receives the source.
struct AddSourceSheet: View {
    @Environment(AppModel.self) private var model
    let source: Source
    let onFinish: (String) -> Void
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            List {
                let candidates = model.router.candidates(for: source)
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No backend for this source",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Add a service that accepts \(source.kind.rawValue) sources in Settings.")
                    )
                } else {
                    Section("Add to") {
                        ForEach(candidates.map { $0.id }, id: \.self) { backendID in
                            Button(backendID.displayName) { add(to: backendID) }
                                .disabled(isWorking)
                        }
                    }
                }
            }
            .navigationTitle(source.kind.rawValue.capitalized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onFinish("") }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func add(to backendID: BackendID) {
        guard let backend = model.backend(backendID) else { return }
        isWorking = true
        Task {
            do {
                try await backend.add(source)
                onFinish("Added to \(backend.id.displayName).")
            } catch {
                onFinish(error.localizedDescription)
            }
        }
    }
}
