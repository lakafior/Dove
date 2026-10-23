import DoveAppCore
import DoveKit
import SwiftUI

struct SeasonRoute: Hashable {
    let titleID: String
    let season: Int
}

/// One row per season on the title screen: how much of it the library holds, and a play button.
struct SeasonRow: View {
    let season: LibrarySeason
    let play: () -> Void

    private var fraction: Double {
        season.episodes.isEmpty ? 0 : Double(season.available.count) / Double(season.episodes.count)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(season.title).font(.headline)
                    Spacer()
                    Text("\(season.available.count)/\(season.episodes.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: fraction)
                    .tint(fraction == 1 ? .green : .accentColor)
                Text(season.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !season.available.isEmpty {
                Button(action: play) { Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(.tint) }
                    // Borderless keeps the button's own tap inside a navigation row.
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Play \(season.title)")
            }
        }
        .foregroundStyle(season.available.isEmpty ? .secondary : .primary)
    }
}

/// A season's episodes, each matched to a file: tap to play, long-press for "play from here", versions,
/// link and download. Missing episodes open their sources, and a season the library lacks (in full or in part)
/// offers its season packs.
struct LibrarySeasonView: View {
    @Environment(AppModel.self) private var model
    let series: SeriesModel
    let titleID: String
    let number: Int

    private var title: LibraryTitle? { model.library.title(id: titleID) }
    /// The detail's summary carries IMDb IDs, which the source search needs.
    private var media: MediaSummary? { series.detail?.summary ?? title?.media }

    var body: some View {
        List {
            if let title, let layout = Optional(series.layout(of: title)),
               let season = layout.seasons.first(where: { $0.number == number }) {
                Section {
                    if !season.available.isEmpty {
                        Button {
                            play(season.available, of: title)
                        } label: {
                            Label("Play \(season.title)", systemImage: "play.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 12))
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                    if let media, let first = season.episodes.first?.info, number > 0,
                       season.available.count < season.episodes.count {
                        NavigationLink {
                            SourcesView(
                                title: "\(media.name) S\(number.twoDigits)",
                                type: .series,
                                id: first.id,
                                scope: .season(number),
                                airedEpisodes: season.episodes.count,
                                searchTitle: media.name,
                                media: media
                            )
                        } label: {
                            Label("Find \(season.title)", systemImage: "magnifyingglass")
                        }
                        .disabled(!model.addonSet.hasStreams)
                    }
                } footer: {
                    Text(series.message ?? season.summary)
                }
                Section {
                    ForEach(season.episodes) { episode in
                        if !episode.isAvailable, let media, let info = episode.info {
                            NavigationLink {
                                EpisodeSourcesView(media: media, episode: info)
                            } label: {
                                EpisodeRowLabel(episode: episode, chosen: nil)
                            }
                            .disabled(!model.addonSet.hasStreams)
                        } else {
                            EpisodeRow(episode: episode, chosen: series.file(for: episode)) {
                                play([episode], of: title)
                            }
                            .contextMenu { menu(for: episode, in: layout, of: title) }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Not in your library anymore", systemImage: "tray")
            }
        }
        .navigationTitle(title.map { "\($0.name) · \(number == 0 ? "Specials" : "Season \(number)")" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) { PreparingBadge(progress: series.preparing) }
    }

    @ViewBuilder
    private func menu(for episode: LibraryEpisode, in layout: SeriesLayout, of title: LibraryTitle) -> some View {
        if episode.isAvailable {
            Button(model.playback.playLabel, systemImage: "play") { play([episode], of: title) }
            PlayInMenu { player in play([episode], of: title, in: player) }
            Button("Play from here", systemImage: "play.square.stack") { play(layout.available(from: episode), of: title) }
            if episode.files.count > 1 {
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
            Button("Copy link", systemImage: "link") { Task { await series.copyLink(episode, using: model) } }
            Button("Download to phone", systemImage: "arrow.down.circle") { Task { await series.download(episode, using: model) } }
        }
    }

    private func play(_ episodes: [LibraryEpisode], of title: LibraryTitle, in player: ExternalPlayer? = nil) {
        Task { await series.play(episodes, of: title, using: model, in: player) }
    }
}

private struct EpisodeRow: View {
    let episode: LibraryEpisode
    let chosen: EpisodeFile?
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            EpisodeRowLabel(episode: episode, chosen: chosen)
        }
        .tint(.primary)
        .disabled(!episode.isAvailable)
        .opacity(episode.isAvailable ? 1 : 0.55)
    }
}

/// An episode's still, title, facts and overview; missing ones are dimmed, with a search mark.
private struct EpisodeRowLabel: View {
    let episode: LibraryEpisode
    let chosen: EpisodeFile?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            still
            VStack(alignment: .leading, spacing: 3) {
                Text("\(episode.number). \(episode.info?.title ?? episode.code)")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let overview = episode.info?.overview, !overview.isEmpty {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .opacity(episode.isAvailable ? 1 : 0.55)
    }

    /// The episode's still (TMDB or the metadata addon), with a play mark when it can be played.
    private var still: some View {
        CachedImage(url: episode.info?.thumbnail) {
            ZStack {
                Rectangle().fill(.quaternary)
                Text(episode.code).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            Image(systemName: episode.isAvailable ? "play.circle.fill" : "magnifyingglass.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.35))
        }
    }

    private var details: String {
        var parts: [String] = []
        if let released = episode.info?.released { parts.append(released.formatted(date: .abbreviated, time: .omitted)) }
        if let chosen {
            parts.append(chosen.item.item.backend.displayName)
            if let resolution = chosen.resolution { parts.append(resolution) }
            if let size = chosen.size { parts.append(size.formatted(.byteCount(style: .file))) }
            if !chosen.isReady { parts.append(chosen.item.item.status.label) }
            if episode.files.count > 1 { parts.append("\(episode.files.count) versions") }
        } else {
            parts.append("Not in your library")
        }
        return parts.joined(separator: " · ")
    }
}


extension SeriesModel {
    /// Copies an episode's link to the iPhone's pasteboard.
    func copyLink(_ episode: LibraryEpisode, using model: AppModel) async {
        do {
            guard let url = try await episodeLink(episode, using: model) else { return }
            UIPasteboard.general.url = url
            message = "Link copied."
        } catch {
            message = error.localizedDescription
        }
    }
}
