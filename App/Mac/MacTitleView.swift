import DoveAppCore
import DoveKit
import SwiftUI

/// A movie or series from search: what it is, then its sources. A movie lists its releases at once; a series puts
/// its seasons and episodes on the left (and whole-season and whole-series packs) and the picked one's releases on
/// the right.
struct MacTitleView: View {
    @Environment(AppModel.self) private var model
    let media: MediaSummary

    @State private var detail: MediaDetail?
    @State private var error: String?
    @State private var season: Int?
    @State private var pick: Pick?

    /// What the right side lists.
    enum Pick: Hashable {
        case episode(Episode)
        case season(Int)
        case series
    }

    private var summary: MediaSummary { detail?.summary ?? media }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.addonSet.hasStreams {
                ContentUnavailableView("No stream addon", systemImage: "puzzlepiece.extension",
                                       description: Text("Add a Stremio addon with streams in Settings."))
            } else if media.type == .movie {
                // TMDB results carry TMDB IDs; the detail brings the IMDb ID stream addons want.
                if detail != nil || error != nil || !media.id.hasPrefix("tmdb:") {
                    MacSourcesTable(query: SourceQuery(type: .movie, id: summary.id, searchTitle: summary.name, media: summary))
                } else {
                    ProgressView().frame(maxHeight: .infinity)
                }
            } else if let detail {
                series(detail)
            } else if let error {
                ContentUnavailableView("No episode list", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(summary.name)
        .task {
            do {
                detail = try await model.addonSet.detail(of: media)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            PosterImage(url: summary.poster)
                .frame(width: 92, height: 138)
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.name).font(.title.bold())
                HStack(spacing: 8) {
                    Text(summary.type == .movie ? "Movie" : "Series")
                    if let year = summary.releaseInfo { Text(year) }
                    if let runtime = detail?.runtime { Text(runtime) }
                    if let genres = detail?.genres, !genres.isEmpty { Text(genres.prefix(3).joined(separator: " · ")) }
                }
                .foregroundStyle(.secondary)
                if let description = summary.description {
                    Text(description).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: Series

    private func series(_ detail: MediaDetail) -> some View {
        let current = season ?? detail.seasons.first { $0 > 0 } ?? detail.seasons.first ?? 1
        let episodes = detail.episodes(inSeason: current)
        return HSplitView {
            List(selection: $pick) {
                if detail.seasons.count > 1 {
                    Picker("Season", selection: Binding(get: { current }, set: { season = $0; pick = nil })) {
                        ForEach(detail.seasons, id: \.self) { number in
                            Text(number == 0 ? "Specials" : "Season \(number)").tag(number)
                        }
                    }
                }
                Section("Packs") {
                    // Packs are found by asking for the first episode and keeping releases whose folder is the season.
                    if current > 0, !episodes.isEmpty {
                        Label("Whole season \(current)", systemImage: "square.stack").tag(Pick.season(current))
                    }
                    if detail.seasons.filter({ $0 > 0 }).count > 1 {
                        Label("Whole series", systemImage: "square.stack.3d.up").tag(Pick.series)
                    }
                }
                Section("\(episodes.count) episodes") {
                    ForEach(episodes) { episode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(episode.number). \(episode.title ?? "Episode \(episode.number)")").lineLimit(1)
                            if let released = episode.released {
                                Text(released.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(Pick.episode(episode))
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 380)

            Group {
                if let query = query(for: pick, in: detail) {
                    MacSourcesTable(query: query).id(query.id + "\(query.scope.map { "\($0)" } ?? "")")
                } else {
                    ContentUnavailableView("Pick an episode", systemImage: "list.bullet",
                                           description: Text("Or a whole season or series for packs."))
                }
            }
            .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func query(for pick: Pick?, in detail: MediaDetail) -> SourceQuery? {
        switch pick {
        case .episode(let episode):
            return SourceQuery(type: .series, id: episode.id, searchTitle: summary.name, media: summary)
        case .season(let number):
            guard let first = detail.episodes(inSeason: number).first else { return nil }
            return SourceQuery(type: .series, id: first.id, searchTitle: summary.name, scope: .season(number), media: summary)
        case .series:
            guard let pilot = detail.episodes(inSeason: detail.seasons.first { $0 > 0 } ?? 1).first else { return nil }
            return SourceQuery(type: .series, id: pilot.id, searchTitle: summary.name, scope: .series, media: summary)
        case nil:
            return nil
        }
    }
}
