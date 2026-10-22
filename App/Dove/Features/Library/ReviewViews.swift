import DoveAppCore
import DoveKit
import SwiftUI

/// Title screen: the series' new and missing episodes, one row per season (one episode opens its sources, several
/// open `MissingSeasonView`). Never adds anything by itself.
struct MissingEpisodesSection: View {
    @Environment(AppModel.self) private var model
    let title: LibraryTitle
    let review: TitleReview
    /// The series' metadata with IMDb IDs (the title screen's detail), for the source search.
    let media: MediaSummary

    private var schedule: EpisodeSchedule? { model.review.schedule(for: title) }

    var body: some View {
        let gaps = review.new + review.missing
        if !gaps.isEmpty {
            Section {
                rows(gaps)
            } header: {
                Text(review.new.isEmpty ? "Missing episodes" : "New episodes")
            } footer: {
                Text("Aired episodes your library does not hold. Hidden ones come back only if newer episodes air.")
            }
        }
    }

    @ViewBuilder
    private func rows(_ all: [Episode]) -> some View {
        ForEach(Self.seasons(all), id: \.self) { season in
            let episodes = all.filter { $0.season == season }.sorted { $0.number < $1.number }
            let isNew = episodes.allSatisfy { episode in review.new.contains { $0.id == episode.id } }
            NavigationLink {
                if episodes.count == 1, let episode = episodes.first {
                    EpisodeSourcesView(media: media, episode: episode)
                } else {
                    MissingSeasonView(media: media, season: season, episodes: episodes, schedule: schedule)
                }
            } label: {
                MissingRow(label: LibraryReview.label(episodes, schedule: schedule), count: episodes.count, isNew: isNew,
                           aired: episodes.compactMap(\.released).max())
            }
            .disabled(!model.addonSet.hasStreams)
        }
        Button("Hide these", systemImage: "eye.slash") {
            model.review.dismissEpisodes(of: title, all)
        }
        .font(.subheadline)
    }

    static func seasons(_ episodes: [Episode]) -> [Int] {
        Array(Set(episodes.map(\.season))).sorted()
    }
}

private struct MissingRow: View {
    let label: String
    let count: Int
    let isNew: Bool
    let aired: Date?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isNew {
                Text("New")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }
        }
    }

    private var detail: String {
        var parts = ["\(count) episode\(count == 1 ? "" : "s")"]
        if let aired { parts.append("aired \(aired.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}

/// Several missing episodes of one season: a season pack when every aired episode is missing, then each episode.
struct MissingSeasonView: View {
    @Environment(AppModel.self) private var model
    let media: MediaSummary
    let season: Int
    let episodes: [Episode]
    let schedule: EpisodeSchedule?

    private var aired: [EpisodeSchedule.Entry] {
        (schedule?.episodes ?? []).filter { $0.season == season && ($0.released ?? .distantPast) <= .now }
    }

    var body: some View {
        List {
            if let first = schedule?.episodes.filter({ $0.season == season }).min(by: { $0.number < $1.number }) {
                Section {
                    NavigationLink {
                        SourcesView(
                            title: "\(media.name) S\(season.twoDigits)",
                            type: .series,
                            id: first.id,
                            scope: .season(season),
                            airedEpisodes: aired.count,
                            searchTitle: media.name,
                            media: media
                        )
                    } label: {
                        Label("Whole season \(season)", systemImage: "square.stack")
                    }
                } footer: {
                    if episodes.count < aired.count {
                        Text("You have \(aired.count - episodes.count) of its episodes; a pack brings the whole season again.")
                    }
                }
            }
            Section("Missing") {
                ForEach(episodes) { episode in
                    NavigationLink {
                        EpisodeSourcesView(media: media, episode: episode)
                    } label: {
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
            }
        }
        .navigationTitle("\(media.name) S\(season.twoDigits)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EpisodeSourcesView: View {
    let media: MediaSummary
    let episode: Episode

    var body: some View {
        SourcesView(
            title: "\(media.name) S\(episode.season.twoDigits)E\(episode.number.twoDigits)",
            type: .series,
            id: episode.id,
            searchTitle: media.name,
            media: media
        )
    }
}

/// Title screen: releases worth replacing (low resolution, poor source, trouble on Apple TV), each opening the
/// sources filtered to better ones.
struct BetterVersionSection: View {
    @Environment(AppModel.self) private var model
    let title: LibraryTitle
    let review: TitleReview
    /// With IMDb IDs: movies' sources need them (`TMDBMetadata.detail`); nil until the detail loads.
    let media: MediaSummary?

    var body: some View {
        if !review.weak.isEmpty {
            Section {
                ForEach(review.weak, id: \.self) { spot in
                    NavigationLink {
                        if let media { sources(for: spot, media: media) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(spot.season.map { "Season \($0): " } ?? "You have ")\(spot.quality.label ?? "unknown quality")")
                            Text(spot.quality.weaknesses.map(Self.explain).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(media == nil || !model.addonSet.hasStreams || firstEpisode(of: spot) == nil && spot.season != nil)
                    .contextMenu {
                        Button("Keep what I have", systemImage: "checkmark") {
                            model.review.dismissQuality(of: title, spot.quality)
                        }
                    }
                }
            } header: {
                Text("Could be better")
            } footer: {
                Text("Opens the sources that beat it. Touch and hold to keep what you have.")
            }
        }
    }

    /// "720p" → "Below 1080p", "DVD" → "DVD source", "AV1" → its Apple TV trouble.
    static func explain(_ weakness: String) -> String {
        switch weakness {
        case "720p", "480p": "Below 1080p"
        case "AV1": "AV1: no hardware decoding on Apple TV"
        default: "\(weakness) source"
        }
    }

    @ViewBuilder
    private func sources(for spot: TitleReview.WeakSpot, media: MediaSummary) -> some View {
        if let season = spot.season, let first = firstEpisode(of: spot) {
            SourcesView(
                title: "\(media.name) S\(season.twoDigits)",
                type: .series,
                id: first.id,
                scope: .season(season),
                searchTitle: media.name,
                media: media,
                upgradeOver: spot.quality
            )
        } else {
            SourcesView(title: media.name, type: .movie, id: media.id, searchTitle: media.name, media: media, upgradeOver: spot.quality)
        }
    }

    private func firstEpisode(of spot: TitleReview.WeakSpot) -> EpisodeSchedule.Entry? {
        guard let season = spot.season else { return nil }
        return model.review.schedule(for: title)?.episodes.filter { $0.season == season }.min { $0.number < $1.number }
    }
}
