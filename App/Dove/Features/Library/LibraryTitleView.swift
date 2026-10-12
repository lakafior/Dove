import DoveKit
import SwiftUI

/// One title across services: artwork and description, then its torrents and downloads by season.
struct LibraryTitleView: View {
    @Environment(AppModel.self) private var model
    let titleID: String
    @State private var isFixingMatch = false
    /// Full metadata (description, genres): search results often leave the description out.
    @State private var detail: MediaDetail?

    private var title: LibraryTitle? { model.library.title(id: titleID) }

    var body: some View {
        List {
            if let title {
                Section {
                    header(title)
                    Button("Wrong title?", systemImage: "arrow.triangle.2.circlepath") { isFixingMatch = true }
                        .font(.footnote)
                }
                ForEach(title.seasons, id: \.season) { group in
                    Section(sectionTitle(group.season, of: title)) {
                        ForEach(group.items) { item in
                            NavigationLink(value: item) { ShelfItemRow(item: item) }
                                .swipeActions {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        Task { try? await model.library.delete(item, using: model) }
                                    }
                                }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Not in your library anymore", systemImage: "tray")
            }
        }
        .navigationTitle(title?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isFixingMatch) {
            if let title { MatchPickerSheet(title: title) }
        }
        .task(id: title?.media?.id) {
            guard let media = title?.media else { return }
            detail = try? await model.addonSet.detail(of: media)
        }
    }

    private func header(_ title: LibraryTitle) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: title.media?.poster)
                .frame(width: 90, height: 135)
            VStack(alignment: .leading, spacing: 6) {
                Text(title.name).font(.title3.bold())
                HStack(spacing: 6) {
                    Text(title.type == .movie ? "Movie" : "Series")
                    if let year = title.year { Text(year) }
                    if title.size > 0 { Text(title.size.formatted(.byteCount(style: .file))) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(title.backends, id: \.self) { BackendBadge(backend: $0) }
                }
                if let genres = detail?.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                if let description = detail?.summary.description ?? title.media?.description {
                    Text(description).font(.footnote).lineLimit(6)
                }
                if title.media == nil {
                    Text("No match from your metadata addon yet.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sectionTitle(_ season: Int?, of title: LibraryTitle) -> String {
        guard title.type == .series else { return "Releases" }
        return season.map { "Season \($0)" } ?? "Other"
    }
}

/// Search the metadata addon and pick the right title; the choice sticks for every release with the same guess.
private struct MatchPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let title: LibraryTitle
    @State private var query = ""
    @State private var results: [MediaSummary] = []
    @State private var isSearching = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title", text: $query)
                        .submitLabel(.search)
                        .onSubmit(search)
                } footer: {
                    if let message { Text(message) }
                }
                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(results) { media in
                    Button {
                        choose(media)
                    } label: {
                        MediaRow(item: media)
                    }
                    .tint(.primary)
                }
            }
            .navigationTitle("Choose the title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                query = title.guess.title
                search()
            }
        }
    }

    private func search() {
        guard model.addonSet.canSearch else {
            message = "Add a Stremio addon that can search in Settings."
            return
        }
        isSearching = true
        Task {
            do {
                results = try await model.addonSet.search(query)
                message = results.isEmpty ? "Nothing found." : nil
            } catch {
                message = error.localizedDescription
            }
            isSearching = false
        }
    }

    private func choose(_ media: MediaSummary) {
        let keys = Set(title.items.map(\.guess.key))
        Task {
            await model.library.setMatch(media, for: keys)
            dismiss()
        }
    }
}
