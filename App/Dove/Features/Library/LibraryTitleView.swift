import DoveKit
import SwiftUI

/// One title across services: artwork and description, then its torrents and downloads by season.
struct LibraryTitleView: View {
    @Environment(AppModel.self) private var model
    let titleID: String
    @State private var isFixingMatch = false
    /// Full metadata (description, genres, episodes): search results often leave the description out.
    @State private var detail: MediaDetail?
    /// Files of packs whose service lists items without files (Real-Debrid, Offcloud), for episode counts.
    @State private var packFiles: [ShelfItem.ID: [LibraryFile]] = [:]

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
                    Section {
                        ForEach(group.items) { item in
                            NavigationLink(value: item) { ShelfItemRow(item: item) }
                                .swipeActions {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        Task { try? await model.library.delete(item, using: model) }
                                    }
                                }
                        }
                    } header: {
                        Text(sectionTitle(group.season, items: group.items, of: title))
                    } footer: {
                        if let season = group.season, let summary = completeness(of: season, in: title) {
                            Text(summary)
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
        .task(id: titleID) { await loadPackFiles() }
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

    /// "All 10 episodes" or "Missing E04, E07 · 8 of 10", once the metadata lists the season's episodes.
    private func completeness(of season: Int, in title: LibraryTitle) -> String? {
        guard title.type == .series, season > 0, let detail else { return nil }
        let have = PackCompleteness.episodes(inSeason: season, items: title.items, files: packFiles)
        return PackCompleteness.summary(have: have, aired: PackCompleteness.airedEpisodes(in: detail, season: season))
    }

    /// Packs listed without files get one detail call each: only this title's, so a handful at most.
    private func loadPackFiles() async {
        guard let title, title.type == .series else { return }
        for item in title.items where item.guess.scope?.isPack == true && item.item.files.isEmpty {
            guard let backend = model.backend(item.item.backend),
                  let loaded = try? await backend.item(item.item.id) else { continue }
            packFiles[item.id] = loaded.files
            model.library.learnKind(from: loaded)
        }
    }

    private func sectionTitle(_ season: Int?, items: [ShelfItem], of title: LibraryTitle) -> String {
        guard title.type == .series else { return "Releases" }
        if let season { return "Season \(season)" }
        let hasMultiSeason = items.contains { $0.guess.scope?.isPack == true }
        return hasMultiSeason ? "Several seasons" : "Other"
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
