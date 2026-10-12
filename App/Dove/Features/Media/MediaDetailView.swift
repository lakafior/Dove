import DoveKit
import SwiftUI

/// A movie or a series: description, then sources (movie) or seasons and episodes (series).
struct MediaDetailView: View {
    @Environment(AppModel.self) private var model
    let item: MediaSummary
    @State private var detail: MediaDetail?
    @State private var season: Int?
    @State private var error: String?

    private var summary: MediaSummary { detail?.summary ?? item }

    var body: some View {
        List {
            Section {
                header
            }

            if let error {
                Text(error).foregroundStyle(.red)
            }

            if item.type == .movie {
                Section {
                    NavigationLink("Sources") {
                        SourcesView(title: summary.name, type: .movie, id: summary.id)
                    }
                    .disabled(!model.addonSet.hasStreams)
                } footer: {
                    if !model.addonSet.hasStreams { Text("Add a Stremio addon with streams in Settings.") }
                }
            } else if let detail {
                episodes(of: detail)
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let loaded = try await model.addonSet.detail(of: item)
                detail = loaded
                season = season ?? loaded.seasons.first
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(url: summary.poster)
                .frame(width: 100, height: 150)
            VStack(alignment: .leading, spacing: 6) {
                Text(summary.name).font(.title3.bold())
                HStack(spacing: 6) {
                    if let year = summary.releaseInfo { Text(year) }
                    if let runtime = detail?.runtime { Text(runtime) }
                    if let rating = summary.imdbRating { Text("★ \(rating)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let genres = detail?.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                if let description = summary.description {
                    Text(description).font(.footnote).lineLimit(6)
                }
            }
        }
    }

    @ViewBuilder
    private func episodes(of detail: MediaDetail) -> some View {
        if detail.seasons.isEmpty {
            Text("No episode list from your metadata addon.").foregroundStyle(.secondary)
        } else {
            let currentSeason = season ?? detail.seasons.first ?? 1
            let firstEpisode = detail.episodes(inSeason: currentSeason).first
            Section {
                Picker("Season", selection: $season) {
                    ForEach(detail.seasons, id: \.self) { number in
                        Text(number == 0 ? "Specials" : "Season \(number)").tag(Optional(number))
                    }
                }
                // Packs are found by asking for the first episode and keeping releases whose folder is the season.
                if let firstEpisode, currentSeason > 0 {
                    NavigationLink {
                        SourcesView(
                            title: "\(summary.name) S\(currentSeason.twoDigits)",
                            type: .series,
                            id: firstEpisode.id,
                            scope: .season(currentSeason)
                        )
                    } label: {
                        Label("Whole season \(currentSeason)", systemImage: "square.stack")
                    }
                    .disabled(!model.addonSet.hasStreams)
                }
                ForEach(detail.episodes(inSeason: currentSeason)) { episode in
                    NavigationLink {
                        SourcesView(
                            title: "\(summary.name) S\(episode.season.twoDigits)E\(episode.number.twoDigits)",
                            type: .series,
                            id: episode.id
                        )
                    } label: {
                        EpisodeRow(episode: episode)
                    }
                    .disabled(!model.addonSet.hasStreams)
                }
            } footer: {
                Text("\(detail.episodes(inSeason: currentSeason).count) episodes")
            }

            if let pilot = detail.episodes(inSeason: detail.seasons.first { $0 > 0 } ?? 1).first, detail.seasons.filter({ $0 > 0 }).count > 1 {
                Section {
                    NavigationLink {
                        SourcesView(title: "\(summary.name) — all seasons", type: .series, id: pilot.id, scope: .series)
                    } label: {
                        Label("Whole series", systemImage: "square.stack.3d.up")
                    }
                    .disabled(!model.addonSet.hasStreams)
                } footer: {
                    Text("Full-series packs are rarer and often incomplete; check the size before adding.")
                }
            }
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(episode.number). \(episode.title ?? "Episode \(episode.number)")")
            if let released = episode.released {
                Text(released.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension Int {
    var twoDigits: String { String(format: "%02d", self) }
}
