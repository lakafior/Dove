import DoveAppCore
import DoveKit
import SwiftUI

/// The route to a season's screen, pushed over a series' page (`MacRouter.pushLibrary`).
struct SeasonRoute: Hashable {
    let title: LibraryTitle
    let number: Int
}

/// One season as a page: its poster and overview, Play Season, then its episodes as a table (`MacEpisodeTable`). A held
/// episode plays on double-click; a missing one is dimmed and opens its sources ("Find"). An episode with several
/// versions lists them under it (disclosure triangles). Shown over the Library (`MacLibraryStack`), where the title shows as the breadcrumb.
struct MacSeasonView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    /// The series as the Library listed it when it was opened; the live one is read from the library below.
    let title: LibraryTitle
    let number: Int

    @State private var series = SeriesModel()
    @State private var isLoadingDetail = false

    /// The series as the library holds it now; nil once it has left the library.
    private var current: LibraryTitle? { model.library.title(id: title.id) }

    /// The season's name as the series' pages give it ("Season 7", "Specials").
    private var seasonName: String { number == 0 ? "Specials" : "Season \(number)" }

    var body: some View {
        Group {
            if let current {
                content(current)
            } else {
                ContentUnavailableView("Not in your library anymore", systemImage: "tray")
            }
        }
        .navigationTitle("\(current?.name ?? title.name) › \(seasonName)")
        .task(id: title.media?.id) {
            guard let media = title.media else { return }
            isLoadingDetail = true
            defer { isLoadingDetail = false }
            await series.loadDetail(of: media, using: model)
        }
        .task(id: title.id) {
            if let current { await series.loadPackFiles(of: current, using: model) }
        }
    }

    @ViewBuilder
    private func content(_ current: LibraryTitle) -> some View {
        let layout = series.layout(of: current)
        if let season = layout.seasons.first(where: { $0.number == number }) {
            VStack(spacing: 0) {
                header(season, of: current)
                Divider()
                MacEpisodeTable(title: current, seasons: [season], layout: layout, series: series)
            }
            .overlay(alignment: .bottom) { PreparingBadge(progress: series.preparing) }
        } else {
            ContentUnavailableView("No episodes in this season", systemImage: "tv",
                                   description: Text(isLoadingDetail ? "Loading the episode list…" : "No file of it is in the library."))
        }
    }

    // MARK: Header

    /// The season's poster (its own, else the series'), name, held/aired count and size, overview, and Play Season.
    private func header(_ season: LibrarySeason, of title: LibraryTitle) -> some View {
        let info = series.detail?.seasonInfo[season.number]
        let poster = info?.poster ?? title.media?.poster ?? series.detail?.summary.poster
        let size = season.available.reduce(Int64(0)) { $0 + (series.file(for: $1)?.size ?? 0) }
        return HStack(alignment: .top, spacing: 20) {
            PosterImage(url: poster)
                .aspectRatio(2 / 3, contentMode: .fit)
                .frame(width: 140)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 8) {
                Text(season.title).font(.largeTitle.bold())
                Text("\(season.available.count) of \(season.episodes.count) episodes held\(size > 0 ? " · \(size.formatted(.byteCount(style: .file)))" : "")")
                    .foregroundStyle(.secondary)
                if let overview = info?.overview, !overview.isEmpty {
                    Text(overview).lineLimit(4).textSelection(.enabled).frame(maxWidth: 680, alignment: .leading)
                }
                if !season.available.isEmpty {
                    Button("Play Season", systemImage: "play.fill") { play(season.available, of: title) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(series.preparing != nil)
                        .padding(.top, 4)
                }
                if let message = series.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: Actions

    private func play(_ episodes: [LibraryEpisode], of title: LibraryTitle, in player: ExternalPlayer? = nil) {
        Task { await series.play(episodes, of: title, using: model, in: player) }
    }
}
