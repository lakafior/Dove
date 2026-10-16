import DoveKit
import SwiftUI

/// One title across services. Series: artwork, "Play all", seasons (each opening its episodes), then the
/// releases they come from. Movies: artwork and releases.
struct LibraryTitleView: View {
    @Environment(AppModel.self) private var model
    let titleID: String
    @State private var isFixingMatch = false
    @State private var series = SeriesModel()

    private var title: LibraryTitle? { model.library.title(id: titleID) }

    var body: some View {
        List {
            if let title {
                Section {
                    TitleHeader(title: title, detail: series.detail)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    playButton(title)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } footer: {
                    if let message = series.message { Text(message) }
                }
                if title.type == .series {
                    seriesSections(title)
                } else {
                    BetterVersionSection(title: title, review: model.review.review(of: title), media: series.detail?.summary)
                    releasesSection(title, header: "Releases")
                }
            } else {
                ContentUnavailableView("Not in your library anymore", systemImage: "tray")
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle(title?.name ?? "")
        // Opening a title tells Spotlight it matters (ranking), linked to its indexed item.
        .userActivity(SpotlightIndex.viewActivity, isActive: title != nil) { activity in
            SpotlightIndex.describe(activity, id: "title:\(titleID)", title: title?.name ?? "")
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let media = title?.media {
                ToolbarItem(placement: .primaryAction) {
                    WatchlistButton(media: media, otherIDs: series.detail.map { [$0.summary.id] } ?? [])
                }
            }
            if title != nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis.circle") {
                        Button("Wrong title?", systemImage: "magnifyingglass") { isFixingMatch = true }
                        Button("Refresh status", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await model.library.refresh(using: model) }
                        }
                        if let title, model.review.hasDismissed(title) {
                            Button("Show hidden suggestions", systemImage: "eye") { model.review.restore(title) }
                        }
                    }
                }
            }
        }
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
            if let detail = series.detail, media.type == .series { await model.review.record(detail, for: media.id) }
        }
        .task(id: titleID) {
            guard let title, title.type == .series else { return }
            await series.loadPackFiles(of: title, using: model)
        }
    }

    /// Series: every episode in the library as one playlist. Movies: the biggest ready release's main video.
    @ViewBuilder
    private func playButton(_ title: LibraryTitle) -> some View {
        let available = title.type == .series ? series.layout(of: title).available : []
        let canPlay = title.type == .series ? !available.isEmpty : title.items.contains { $0.item.status == .ready }
        if canPlay {
            Button {
                if title.type == .series {
                    play(available, of: title)
                } else {
                    Task { await series.playMovie(title, using: model) }
                }
            } label: {
                Label(title.type == .series ? "Play all" : "Play", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 12))
            .disabled(series.preparing != nil)
        }
    }

    @ViewBuilder
    private func seriesSections(_ title: LibraryTitle) -> some View {
        let layout = series.layout(of: title)
        if layout.hasEpisodes {
            Section("Seasons") {
                ForEach(layout.seasons) { season in
                    NavigationLink(value: SeasonRoute(titleID: titleID, season: season.number)) {
                        SeasonRow(season: season) { play(season.available, of: title) }
                    }
                }
            }
        }
        let review = model.review.review(of: title, files: series.packFiles)
        if let media = series.detail?.summary ?? title.media {
            MissingEpisodesSection(title: title, review: review, media: media)
        }
        BetterVersionSection(title: title, review: review, media: series.detail?.summary ?? title.media)
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
        Task { await series.play(episodes, of: title, using: model) }
    }
}

/// Backdrop (or the poster, blurred) with the poster, name and facts over it; then genres and the description,
/// which opens up on a tap.
private struct TitleHeader: View {
    let title: LibraryTitle
    let detail: MediaDetail?
    @State private var showsFullDescription = false

    private var backdrop: URL? { detail?.summary.background ?? title.media?.background }
    private var poster: URL? { title.media?.poster ?? detail?.summary.poster }

    private var facts: String {
        var parts = [title.type == .movie ? "Movie" : "Series"]
        if let year = title.year { parts.append(year) }
        if let runtime = detail?.runtime { parts.append(runtime) }
        if title.size > 0 { parts.append(title.size.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                artwork
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .bottom, spacing: 12) {
                    CachedImage(url: poster) { Rectangle().fill(.ultraThinMaterial) }
                        .frame(width: 76, height: 114)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .shadow(radius: 6, y: 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title.name).font(.title2.bold()).lineLimit(2)
                        Text(facts).font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                        HStack(spacing: 4) {
                            ForEach(title.backends, id: \.self) { BackendBadge(backend: $0) }
                            if let coverage = title.coverage {
                                Text(coverage).font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.white.opacity(0.2), in: Capsule())
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if let genres = detail?.genres, !genres.isEmpty {
                Text(genres.prefix(4).joined(separator: " · "))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let description = detail?.summary.description ?? title.media?.description {
                Text(description)
                    .font(.subheadline)
                    .lineLimit(showsFullDescription ? nil : 4)
                    .onTapGesture { withAnimation(.snappy) { showsFullDescription.toggle() } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(showsFullDescription ? "Shows less" : "Shows the whole description")
            }
            if title.media == nil {
                Text("No match from TMDB or your metadata addon yet. Use ⋯ › Wrong title? to pick one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var artwork: some View {
        if let backdrop {
            CachedImage(url: backdrop) { Rectangle().fill(.quaternary) }
        } else if let poster {
            CachedImage(url: poster) { Rectangle().fill(.quaternary) }
                .blur(radius: 24)
                .scaleEffect(1.3)
        } else {
            LinearGradient(colors: [.accentColor.opacity(0.6), .accentColor.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)
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
