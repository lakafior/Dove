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
            Section {
                Picker("Season", selection: $season) {
                    ForEach(detail.seasons, id: \.self) { number in
                        Text(number == 0 ? "Specials" : "Season \(number)").tag(Optional(number))
                    }
                }
                ForEach(detail.episodes(inSeason: season ?? 1)) { episode in
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
            }
            // TODO(stage-2): "Whole season" — query S{n}E1, keep season packs, add without file index.
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
