import DoveKit
import SwiftUI

/// One title across services. Series: artwork, "Play all", seasons (each opening its episodes), then the
/// releases they come from. Movies: artwork and releases.
struct LibraryTitleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let titleID: String
    @State private var isFixingMatch = false
    @State private var series = SeriesModel()

    private var title: LibraryTitle? { model.library.title(id: titleID) }

    var body: some View {
        List {
            if let title {
                Section {
                    header(title)
                    Button("Wrong title?", systemImage: "arrow.triangle.2.circlepath") { isFixingMatch = true }
                        .font(.footnote)
                }
                if title.type == .series {
                    seriesSections(title)
                } else {
                    releasesSection(title, header: "Releases")
                }
            } else {
                ContentUnavailableView("Not in your library anymore", systemImage: "tray")
            }
        }
        .navigationTitle(title?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: SeasonRoute.self) { route in
            LibrarySeasonView(series: series, titleID: route.titleID, number: route.season)
        }
        .overlay(alignment: .bottom) { PreparingBadge(progress: series.preparing) }
        .sheet(isPresented: $isFixingMatch) {
            if let title { MatchPickerSheet(title: title) }
        }
        // Search results often leave the description out; series also need the episode list.
        .task(id: title?.media?.id) {
            guard let media = title?.media else { return }
            await series.loadDetail(of: media, using: model)
        }
        .task(id: titleID) {
            guard let title, title.type == .series else { return }
            await series.loadPackFiles(of: title, using: model)
        }
    }

    @ViewBuilder
    private func seriesSections(_ title: LibraryTitle) -> some View {
        let layout = series.layout(of: title)
        if layout.hasEpisodes {
            Section {
                Button {
                    play(layout.available, of: title)
                } label: {
                    Label("Play all", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } footer: {
                if let message = series.message { Text(message) }
            }
            Section("Seasons") {
                ForEach(layout.seasons) { season in
                    NavigationLink(value: SeasonRoute(titleID: titleID, season: season.number)) {
                        SeasonRow(season: season) { play(season.available, of: title) }
                    }
                }
            }
        }
        releasesSection(title, header: "Releases", footer: unplacedNote(layout))
    }

    /// The torrents and jobs themselves, for actions (reinsert, move, delete) and files Dove could not place.
    private func releasesSection(_ title: LibraryTitle, header: String, footer: String? = nil) -> some View {
        Section {
            ForEach(title.seasons.flatMap(\.items)) { item in
                NavigationLink(value: item) { ShelfItemRow(item: item) }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            Task { await model.library.delete(item, using: model) }
                        }
                    }
            }
        } header: {
            Text(header)
        } footer: {
            if let footer { Text(footer) }
        }
    }

    private func unplacedNote(_ layout: SeriesLayout) -> String? {
        let count = layout.unplaced.count
        guard count > 0 else { return nil }
        return "\(count) video file\(count == 1 ? "" : "s") without an episode number (extras, oddly named files): open the release to play \(count == 1 ? "it" : "them")."
    }

    private func play(_ episodes: [LibraryEpisode], of title: LibraryTitle) {
        Task { await series.play(episodes, of: title, using: model, open: openURL) }
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
                if let genres = series.detail?.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                if let description = series.detail?.summary.description ?? title.media?.description {
                    Text(description).font(.footnote).lineLimit(6)
                }
                if title.media == nil {
                    Text("No match from your metadata addon yet.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Search the metadata addon and pick the right title; the choice sticks for every release with the same guess.
struct MatchPickerSheet: View {
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
            message = "Add a TMDB key or a Stremio addon that can search in Settings."
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
