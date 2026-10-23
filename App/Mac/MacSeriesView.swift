import DoveAppCore
import DoveKit
import SwiftUI

/// A series as a page: a backdrop with the poster, facts, a summary line (seasons, episodes held, size), Play All and
/// the Releases sheet. Its seasons come as icons (season posters, held and aired counts, overview, Play Season) or as a
/// table; a click opens the season (`MacSeasonView`) over the Library. Works from the held files while the episode
/// list is still loading.
struct MacSeriesView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    /// The title as the Library listed it when it was opened; the live one is read from the library below.
    let title: LibraryTitle

    @AppStorage(LibraryViewMode.storageKey) private var mode: LibraryViewMode = .icons
    @State private var series = SeriesModel()
    @AppStorage("macAlbumTab") private var tab: PageTab = .contents
    @State private var isLoadingDetail = false
    @State private var isPickingMatch = false
    @State private var pendingDelete: [ShelfItem] = []

    /// The title as the library holds it now; nil once it has left the library.
    private var current: LibraryTitle? { model.library.title(id: title.id) }

    var body: some View {
        if let current {
            Group {
                if mode == .icons && tab == .contents {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header(current)
                            PageTabPicker(tab: $tab, contents: "Seasons", releases: current.items.count)
                            seasons(current)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 32)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        header(current)
                        PageTabPicker(tab: $tab, contents: "Seasons", releases: current.items.count)
                        if tab == .releases {
                            MacHeldReleases(items: current.items)
                        } else {
                            seasons(current)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .overlay(alignment: .bottom) { PreparingBadge(progress: series.preparing) }
            .navigationTitle(current.name)
            .toolbar {
                // Where the Finder has it: first in the trailing group, before the actions and search.
                ToolbarItem(placement: .primaryAction) {
                    ViewModePicker(mode: $mode)
                }
                if let media = current.media {
                    ToolbarItem { WatchlistButton(media: media) }
                }
            }
            .sheet(isPresented: $isPickingMatch) {
                MatchPickerSheet(title: current).frame(minWidth: 460, minHeight: 520)
            }
            .confirmationDialog("Delete \(current.name)?",
                                isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
                Button("Delete \(pendingDelete.count == 1 ? "1 Release" : "\(pendingDelete.count) Releases")", role: .destructive) {
                    let items = pendingDelete
                    Task { await model.library.delete(items, using: model) }
                }
            } message: {
                Text("They are deleted on the services that hold them.")
            }
            .task(id: current.media?.id) { await loadDetail(current) }
            .task(id: current.id) { await series.loadPackFiles(of: current, using: model) }
        } else {
            ContentUnavailableView("Not in your library anymore", systemImage: "tray")
        }
    }

    // MARK: Header

    /// The page header (`MacPageHeader`): poster, facts, the held/aired summary, Play All, Download and ⋯, the
    /// description, then suggestions (`MacReviewSection`) and loading notes.
    private func header(_ title: LibraryTitle) -> some View {
        let detail = series.detail
        var facts = facts(title, runtime: detail?.runtime)
        if let summary = summary(title) { facts += " · " + summary }
        if let genres = detail?.genres, !genres.isEmpty { facts += "\n" + genres.prefix(4).joined(separator: " · ") }
        let available = series.layout(of: title).available
        return MacPageHeader(
            title: title.name, facts: facts,
            description: detail?.summary.description ?? title.media?.description,
            backdrop: detail?.summary.background ?? title.media?.background,
            cover: title.media?.poster ?? detail?.summary.poster, artworkWidth: 160
        ) {
            PosterImage(url: title.media?.poster ?? detail?.summary.poster)
                .aspectRatio(2 / 3, contentMode: .fit)
        } badges: {
            ForEach(title.backends, id: \.self) { BackendBadge(backend: $0) }
            if let coverage = title.coverage {
                Text(coverage).font(.caption.bold())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
            }
        } buttons: {
            if !available.isEmpty {
                Button("Play All", systemImage: "play.fill") { play(available, of: title) }
                    .buttonStyle(.borderedProminent)
                    .disabled(series.preparing != nil)
            }
            MacItemsButtons(items: title.items, actions: actions) { pageMenu(title) }
        } notes: {
            MacReviewSection(title: title, media: series.detail?.summary ?? title.media, files: series.packFiles)
            if title.media == nil {
                Text("No match from TMDB or your metadata addon yet. Use Wrong Title? in the ⋯ menu.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isLoadingDetail && detail == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading episodes…").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let message = series.message {
                Text(message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    /// "Series · 2019 · 45 min" in the order iOS shows it.
    private func facts(_ title: LibraryTitle, runtime: String?) -> String {
        var parts = [title.type == .movie ? "Movie" : "Series"]
        if let year = title.year { parts.append(year) }
        if let runtime { parts.append(runtime) }
        return parts.joined(separator: " · ")
    }

    /// "3 seasons · 12/24 episodes · 12 GB": seasons, episodes held out of those aired, and the size held.
    private func summary(_ title: LibraryTitle) -> String? {
        let layout = series.layout(of: title)
        guard !layout.seasons.isEmpty else { return nil }
        let aired = layout.seasons.reduce(0) { $0 + $1.episodes.count }
        let seasons = layout.seasons.count
        var parts = ["\(seasons) season\(seasons == 1 ? "" : "s")", "\(layout.available.count)/\(aired) episodes"]
        if title.size > 0 { parts.append(title.size.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }

    // MARK: Seasons

    /// The seasons as icons or as a table, then the video files that could not be placed on an episode.
    @ViewBuilder
    private func seasons(_ title: LibraryTitle) -> some View {
        let layout = series.layout(of: title)
        if layout.seasons.isEmpty {
            if !isLoadingDetail {
                ContentUnavailableView("No episodes yet", systemImage: "tv",
                                       description: Text("Its files are not listed, and no episode list came back."))
            }
        } else if mode == .icons {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], alignment: .leading, spacing: 24) {
                    ForEach(layout.seasons) { season in
                        seasonCard(season, of: title)
                    }
                }
                unplacedNote(layout)
            }
        } else {
            // Seasons open downwards onto their episodes, as folders in the Finder's list view.
            MacEpisodeTable(title: title, seasons: layout.seasons, layout: layout, series: series, groupsSeasons: true)
                .frame(maxHeight: .infinity)
        }
    }

    /// A season's icon: its poster (its own, else the series'), name, held/aired count and bar, the overview, Play Season.
    /// A click opens the season.
    private func seasonCard(_ season: LibrarySeason, of title: LibraryTitle) -> some View {
        let info = series.detail?.seasonInfo[season.number]
        let fraction = season.episodes.isEmpty ? 0 : Double(season.available.count) / Double(season.episodes.count)
        return VStack(alignment: .leading, spacing: 8) {
            PosterImage(url: info?.poster ?? title.media?.poster ?? series.detail?.summary.poster)
                .aspectRatio(2 / 3, contentMode: .fit)
            Text(season.title).font(.callout.weight(.semibold)).lineLimit(1)
            ProgressView(value: fraction)
                .tint(fraction == 1 ? .green : .accentColor)
            Text("\(season.available.count)/\(season.episodes.count) episodes")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let overview = info?.overview, !overview.isEmpty {
                Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if !season.available.isEmpty {
                Button("Play Season", systemImage: "play.fill") { play(season.available, of: title) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(series.preparing != nil)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(.rect)
        .onTapGesture { router.pushLibrary(SeasonRoute(title: title, number: season.number)) }
        .contextMenu {
            Button("Open \(season.title)", systemImage: "arrow.up.forward.square") {
                router.pushLibrary(SeasonRoute(title: title, number: season.number))
            }
            if !season.available.isEmpty {
                Button("Play \(season.title)", systemImage: "play") { play(season.available, of: title) }
                PlayInMenu { player in Task { await series.play(season.available, of: title, using: model, in: player) } }
            }
            if season.available.count < season.episodes.count, let media = series.detail?.summary ?? title.media {
                Divider()
                Button("Find \(season.title)", systemImage: "magnifyingglass") { router.pushLibrary(media) }
            }
        }
        .hoverLift()
    }

    @ViewBuilder
    private func unplacedNote(_ layout: SeriesLayout) -> some View {
        if !layout.unplaced.isEmpty {
            let count = layout.unplaced.count
            Text("\(count) video file\(count == 1 ? "" : "s") without an episode number: open the Releases tab to play \(count == 1 ? "it" : "them").")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private var actions: MacLibraryActions {
        .standard(model: model, report: { series.message = $0 }, confirmDelete: { pendingDelete = $0 })
    }

    /// The page's own items at the top of the header's ⋯ (the iPhone title screen's ⋯).
    @ViewBuilder
    private func pageMenu(_ title: LibraryTitle) -> some View {
        Button("Wrong Title?", systemImage: "wand.and.stars") { isPickingMatch = true }
        if model.review.hasDismissed(title) {
            Button("Show Hidden Suggestions", systemImage: "eye") { model.review.restore(title) }
        }
    }

    private func loadDetail(_ title: LibraryTitle) async {
        guard let media = title.media else { return }
        isLoadingDetail = true
        defer { isLoadingDetail = false }
        await series.loadDetail(of: media, using: model)
    }

    private func play(_ episodes: [LibraryEpisode], of title: LibraryTitle) {
        Task { await series.play(episodes, of: title, using: model) }
    }
}
