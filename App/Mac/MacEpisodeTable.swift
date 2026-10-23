import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// A series' episodes as a Finder-like table. On a series' page (`groupsSeasons`) each season is a row that opens
/// downwards onto its episodes; on a season's page the episodes are the top rows. An episode with several versions
/// lists them under it. Every action of the iPhone's episode rows is here: Play, Play in…, Play from Here, Version,
/// Copy Link, Download, Find for a missing one; a season's: Play Season, Open, Find.
struct MacEpisodeTable: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    let title: LibraryTitle
    let seasons: [LibrarySeason]
    let layout: SeriesLayout
    let series: SeriesModel
    /// Seasons as parent rows (a series' page) or episodes at the top (a season's page).
    var groupsSeasons = false

    @State private var selection = Set<EpisodeRow.ID>()

    var body: some View {
        let rows = rows()
        Table(rows, children: \.children, selection: $selection) {
            TableColumn("#") { row in numberCell(row) }
                .width(64)
            TableColumn("Title") { row in titleCell(row) }
                .width(min: 220, ideal: 360)
            TableColumn("Aired") { row in airedCell(row) }
                .width(min: 90, ideal: 110)
            TableColumn("Version") { row in versionCell(row) }
                .width(min: 160, ideal: 240)
            TableColumn("Size") { row in sizeCell(row) }
                .width(min: 70, ideal: 90)
            TableColumn("") { row in actionCell(row) }
                .width(min: 100, ideal: 130)
        }
.takesFocusWhenSelected(selection)
        .contextMenu(forSelectionType: EpisodeRow.ID.self) { ids in
            let selected = chosen(ids, in: rows)
            if selected.count == 1, let row = selected.first {
                menu(row)
            } else {
                // Several episodes: play them in order, as one playlist.
                let episodes = selected.compactMap(\.episode).filter(\.isAvailable)
                if !episodes.isEmpty {
                    Button("Play \(episodes.count) Episodes", systemImage: "play") { play(episodes) }
                }
            }
        } primaryAction: { ids in
            // Double-click: a season opens, a held episode (or version) plays.
            guard let row = chosen(ids, in: rows).first else { return }
            switch row.kind {
            case .season(let season): open(season)
            case .episode(let episode, _) where episode.isAvailable: play([episode])
            case .version(let episode, let file):
                series.choice[episode.id] = file
                play([episode])
            default: break
            }
        }
    }

    // MARK: Rows

    private func rows() -> [EpisodeRow] {
        if groupsSeasons {
            return seasons.map { season in
                EpisodeRow(id: "s\(season.number)", kind: .season(season), children: season.episodes.map(episodeRow))
            }
        }
        return seasons.flatMap(\.episodes).map(episodeRow)
    }

    private func episodeRow(_ episode: LibraryEpisode) -> EpisodeRow {
        let versions = episode.files.count > 1
            ? episode.files.map { EpisodeRow(id: "\(episode.id)#\($0.id)", kind: .version(episode, $0), children: nil) }
            : nil
        return EpisodeRow(id: episode.id, kind: .episode(episode, series.file(for: episode)), children: versions)
    }

    /// The selected rows with their children flattened in.
    private func chosen(_ ids: Set<EpisodeRow.ID>, in rows: [EpisodeRow]) -> [EpisodeRow] {
        rows.flatMap { row in [row] + chosen(ids, in: row.children ?? []) }.filter { ids.contains($0.id) }
    }

    // MARK: Cells

    @ViewBuilder
    private func numberCell(_ row: EpisodeRow) -> some View {
        switch row.kind {
        case .season(let season):
            Text(season.number == 0 ? "S00" : String(format: "S%02d", season.number)).monospacedDigit().bold()
        case .episode(let episode, _):
            Text(String(format: "E%02d", episode.number)).monospacedDigit().foregroundStyle(.secondary)
        case .version:
            EmptyView()
        }
    }

    @ViewBuilder
    private func titleCell(_ row: EpisodeRow) -> some View {
        switch row.kind {
        case .season(let season):
            let fraction = season.episodes.isEmpty ? 0 : Double(season.available.count) / Double(season.episodes.count)
            HStack(spacing: 8) {
                Text(season.title).fontWeight(.semibold).lineLimit(1)
                Text("\(season.available.count)/\(season.episodes.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                ProgressView(value: fraction)
                    .tint(fraction == 1 ? .green : .accentColor)
                    .frame(width: 60)
            }
            .help(series.detail?.seasonInfo[season.number]?.overview ?? "")
        case .episode(let episode, _):
            Text(episode.info?.title ?? episode.code)
                .lineLimit(1)
                .foregroundStyle(episode.isAvailable ? .primary : .secondary)
                .help(episode.info?.overview ?? "")
        case .version(_, let file):
            Text(file.name).lineLimit(1).truncationMode(.middle).help(file.name)
        }
    }

    @ViewBuilder
    private func airedCell(_ row: EpisodeRow) -> some View {
        switch row.kind {
        case .season(let season):
            let aired = series.detail?.seasonInfo[season.number]?.airDate ?? season.episodes.compactMap { $0.info?.released }.min()
            if let aired { Text(aired.formatted(.dateTime.year())).monospacedDigit() }
        case .episode(let episode, _):
            if let released = episode.info?.released {
                Text(released.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(episode.isAvailable ? .primary : .secondary)
            }
        case .version:
            EmptyView()
        }
    }

    @ViewBuilder
    private func versionCell(_ row: EpisodeRow) -> some View {
        switch row.kind {
        case .season(let season):
            let backends = Set(season.available.compactMap { series.file(for: $0)?.item.item.backend })
            HStack(spacing: 4) {
                ForEach(backends.sorted { $0.rawValue < $1.rawValue }, id: \.self) { BackendBadge(backend: $0) }
            }
        case .episode(_, let file):
            if let file {
                Text(file.label(withSize: false)).lineLimit(1)
            } else {
                Text("Not in your library").foregroundStyle(.secondary)
            }
        case .version(let episode, let file):
            HStack(spacing: 4) {
                if series.file(for: episode) == file { Image(systemName: "checkmark").foregroundStyle(.tint) }
                Text(file.label(withSize: false)).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func sizeCell(_ row: EpisodeRow) -> some View {
        let size: Int64? = switch row.kind {
        case .season(let season): season.available.reduce(Int64(0)) { $0 + (series.file(for: $1)?.size ?? 0) }
        case .episode(_, let file): file?.size
        case .version(_, let file): file.size
        }
        if let size, size > 0 {
            Text(size.formatted(.byteCount(style: .file))).monospacedDigit()
        }
    }

    /// Play for what is held, Find for what is not; a season gets Play Season.
    @ViewBuilder
    private func actionCell(_ row: EpisodeRow) -> some View {
        Group {
            switch row.kind {
            case .season(let season):
                if !season.available.isEmpty {
                    Button("Play", systemImage: "play.fill") { play(season.available) }
                        .help("Play \(season.title)")
                } else {
                    findButton
                }
            case .episode(let episode, _):
                if episode.isAvailable {
                    Button("Play", systemImage: "play.fill") { play([episode]) }
                } else {
                    findButton
                }
            case .version(let episode, let file):
                Button("Play", systemImage: "play.fill") {
                    series.choice[episode.id] = file
                    play([episode])
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(series.preparing != nil)
    }

    @ViewBuilder
    private var findButton: some View {
        if let media {
            Button("Find", systemImage: "magnifyingglass") { router.pushLibrary(media) }
        }
    }

    // MARK: Menus

    @ViewBuilder
    private func menu(_ row: EpisodeRow) -> some View {
        switch row.kind {
        case .season(let season):
            if groupsSeasons {
                Button("Open \(season.title)", systemImage: "arrow.up.forward.square") { open(season) }
            }
            if !season.available.isEmpty {
                Button("Play \(season.title)", systemImage: "play") { play(season.available) }
                PlayInMenu { player in play(season.available, in: player) }
            }
            if season.available.count < season.episodes.count, let media {
                Divider()
                Button("Find \(season.title)", systemImage: "magnifyingglass") { router.pushLibrary(media) }
            }
        case .episode(let episode, _):
            if episode.isAvailable {
                Button(model.playback.playLabel, systemImage: "play") { play([episode]) }
                PlayInMenu { player in play([episode], in: player) }
                Button("Play from Here", systemImage: "play.square.stack") { play(layout.available(from: episode)) }
                if episode.files.count > 1 { versionMenu(episode) }
                Divider()
                Button("Copy Link", systemImage: "link") { copyLink(episode) }
                Button("Download to This Mac", systemImage: "arrow.down.circle") {
                    Task { await series.download(episode, using: model) }
                }
            } else if let media {
                Button("Find", systemImage: "magnifyingglass") { router.pushLibrary(media) }
            }
        case .version(let episode, let file):
            Button(model.playback.playLabel, systemImage: "play") {
                series.choice[episode.id] = file
                play([episode])
            }
            Button("Use This Version", systemImage: "checkmark") { series.choice[episode.id] = file }
        }
    }

    private func versionMenu(_ episode: LibraryEpisode) -> some View {
        Menu("Version", systemImage: "square.stack.3d.up") {
            ForEach(episode.files) { file in
                Button {
                    series.choice[episode.id] = file
                } label: {
                    if series.file(for: episode) == file {
                        Label(file.versionLabel, systemImage: "checkmark")
                    } else {
                        Text(file.versionLabel)
                    }
                }
            }
        }
    }

    // MARK: Actions

    /// The series with IMDb IDs when the detail has loaded (sources need them), else the library's match.
    private var media: MediaSummary? { series.detail?.summary ?? title.media }

    private func open(_ season: LibrarySeason) {
        router.pushLibrary(SeasonRoute(title: title, number: season.number))
    }

    private func play(_ episodes: [LibraryEpisode], in player: ExternalPlayer? = nil) {
        Task { await series.play(episodes, of: title, using: model, in: player) }
    }

    /// The episode's playable link on the pasteboard (the same one-line link iOS copies).
    private func copyLink(_ episode: LibraryEpisode) {
        Task {
            do {
                guard let url = try await series.episodeLink(episode, using: model) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                series.message = "Link copied."
            } catch {
                series.message = error.localizedDescription
            }
        }
    }
}

/// One row of the episode table: a season (on a series' page), an episode, or one of an episode's versions.
struct EpisodeRow: Identifiable {
    enum Kind {
        case season(LibrarySeason)
        /// The episode with the version it plays (nil when it is not held).
        case episode(LibraryEpisode, EpisodeFile?)
        case version(LibraryEpisode, EpisodeFile)
    }

    let id: String
    let kind: Kind
    let children: [EpisodeRow]?

    var episode: LibraryEpisode? {
        switch kind {
        case .season: nil
        case .episode(let episode, _), .version(let episode, _): episode
        }
    }
}
