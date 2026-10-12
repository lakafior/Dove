import DoveKit
import SwiftUI

/// The smart field: a magnet, info hash, .torrent/.nzb URL or hoster link opens the add sheet;
/// anything else searches titles through the user's Stremio addons.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var pendingSource: Source?
    @State private var message: String?
    @State private var results: [MediaSummary] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title, magnet or link", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit(handleSubmit)
                } footer: {
                    if let message { Text(message) }
                }

                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }

                ForEach(results) { item in
                    NavigationLink(value: item) { MediaRow(item: item) }
                }
            }
            .navigationTitle("Dove")
            .navigationDestination(for: MediaSummary.self) { MediaDetailView(item: $0) }
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
        message = nil
        if let source = SourceDetector.detect(text) {
            results = []
            pendingSource = source
            return
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        guard model.addonSet.canSearch else {
            message = "Add a Stremio addon that can search (for example AIOMetadata or Cinemeta) in Settings."
            return
        }
        isSearching = true
        Task {
            do {
                results = try await model.addonSet.search(query)
                if results.isEmpty { message = "Nothing found." }
            } catch {
                message = error.localizedDescription
            }
            isSearching = false
        }
    }
}

struct MediaRow: View {
    let item: MediaSummary

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: item.poster)
                .frame(width: 46, height: 69)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.type == .movie ? "Movie" : "Series")
                    if let year = item.releaseInfo { Text(year) }
                    if let rating = item.imdbRating { Text("★ \(rating)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct PosterImage: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// "Automatic" walks the priority list from Settings; picking a service sends it there only.
struct AddSourceSheet: View {
    @Environment(AppModel.self) private var model
    let source: Source
    let onFinish: (String) -> Void
    @State private var working: Target?

    enum Target: Hashable {
        case automatic
        case backend(BackendID)
    }

    var body: some View {
        NavigationStack {
            List {
                let candidates = model.router.candidates(for: source).map(\.id)
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No backend for this source",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Add a service that accepts \(source.kind.rawValue) sources in Settings.")
                    )
                } else {
                    if candidates.count > 1 {
                        Section {
                            row(.automatic) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Automatic")
                                    Text(candidates.map(\.displayName).joined(separator: " → "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section("Only to") {
                        ForEach(candidates, id: \.self) { id in
                            row(.backend(id)) { Text(id.displayName) }
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
        .interactiveDismissDisabled(working != nil)
    }

    private func row(_ target: Target, @ViewBuilder label: () -> some View) -> some View {
        Button { add(target) } label: {
            HStack {
                label()
                Spacer()
                if working == target { ProgressView() }
            }
        }
        .disabled(working != nil)
    }

    private func add(_ target: Target) {
        working = target
        Task {
            do {
                switch target {
                case .automatic:
                    let result = try await model.router.add(source)
                    let skipped = result.skipped
                        .map { "\($0.backend.displayName): \($0.error.localizedDescription)" }
                        .joined(separator: "\n")
                    onFinish("Added to \(result.backend.displayName)." + (skipped.isEmpty ? "" : "\n\(skipped)"))
                case .backend(let id):
                    guard let backend = model.backend(id) else { return }
                    try await backend.add(source)
                    onFinish("Added to \(id.displayName).")
                }
            } catch {
                onFinish(error.localizedDescription)
            }
        }
    }
}
