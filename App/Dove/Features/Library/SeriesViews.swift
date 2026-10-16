import DoveKit
import SwiftUI

/// A series' seasons and episodes on the title screen and its season screens: metadata, files of packs whose
/// service lists them separately, the version picked per episode, and playing several episodes as one playlist.
@MainActor
@Observable
final class SeriesModel {
    /// Full metadata: episode list and titles, description, genres.
    var detail: MediaDetail?
    /// Files of packs whose service lists items without files (Real-Debrid, Offcloud).
    private(set) var packFiles: [ShelfItem.ID: [LibraryFile]] = [:]
    /// A version the user picked for an episode instead of the preferred one.
    var choice: [LibraryEpisode.ID: EpisodeFile] = [:]
    /// Links being fetched for a playlist.
    private(set) var preparing: (done: Int, total: Int)?
    var message: String?

    func layout(of title: LibraryTitle) -> SeriesLayout {
        SeriesLayout(items: title.items, files: packFiles, detail: detail)
    }

    func file(for episode: LibraryEpisode) -> EpisodeFile? {
        choice[episode.id] ?? episode.files.first
    }

    func loadDetail(of media: MediaSummary, using model: AppModel) async {
        detail = try? await model.addonSet.detail(of: media)
    }

    /// Packs and unlabelled releases listed without files get one detail call each: only this title's, so a
    /// handful at most. Single episodes wait until they are played.
    func loadPackFiles(of title: LibraryTitle, using model: AppModel) async {
        for item in title.items where item.guess.scope?.isPack != false && item.item.files.isEmpty && packFiles[item.id] == nil {
            guard let backend = model.backend(item.item.backend),
                  let loaded = try? await backend.item(item.item.id) else { continue }
            packFiles[item.id] = loaded.files
            model.library.learnKind(from: loaded)
        }
    }

    /// Fetches a link per episode (a few at a time, kept in order) and hands the player one playlist. Players
    /// without playlists get the first episode only, and only its link is fetched.
    /// Episodes whose link fails are skipped and reported.
    func play(_ episodes: [LibraryEpisode], of title: LibraryTitle, using model: AppModel, in player: ExternalPlayer? = nil) async {
        guard preparing == nil else { return }
        let all = EpisodePlaylist(episodes, title: title.name, choice: choice).entries
        let entries = model.playback.limit(all, for: player)
        guard !entries.isEmpty else { return }
        message = nil
        preparing = (0, entries.count)
        defer { preparing = nil }

        let jobs = entries.map { entry in
            let backend = model.backend(entry.file.item.item.backend)
            return { @Sendable in try await Self.link(for: entry.file, on: backend) }
        }
        let (urls, failure) = await LinkBatch.fetch(jobs) { done in self.preparing = (done, entries.count) }

        let playable = zip(entries, urls).compactMap { entry, url in url.map { PlayEntry(url: $0, filename: entry.filename) } }
        guard !playable.isEmpty else {
            message = failure ?? "Nothing to play."
            return
        }
        do {
            try await model.playback.play(playable, in: player)
        } catch {
            message = error.localizedDescription
            return
        }
        if let failure, playable.count < entries.count {
            message = "Skipped \(entries.count - playable.count) of \(entries.count): \(failure)"
        } else {
            message = model.playback.singleFileNote(requested: all.count, for: player)
        }
    }

    /// A movie's "Play": the biggest ready release (best version first), its main video. Releases listed without
    /// files get their detail call here.
    func playMovie(_ title: LibraryTitle, using model: AppModel, in player: ExternalPlayer? = nil) async {
        guard preparing == nil else { return }
        let ready = title.items
            .filter { $0.item.status == .ready }
            .sorted { ($0.item.size ?? 0) > ($1.item.size ?? 0) }
        guard let item = ready.first, let backend = model.backend(item.item.backend) else { return }
        message = nil
        preparing = (0, 1)
        defer { preparing = nil }
        do {
            let file = try await Self.resolve(EpisodeFile(item: item, file: nil), on: backend)
            let url = try await backend.playbackURL(itemID: item.item.id, fileID: file.id)
            let name = (file.name as NSString).lastPathComponent
            try await model.playback.play([PlayEntry(url: url, filename: name)], in: player)
        } catch {
            message = error.localizedDescription
        }
    }

    func copyLink(_ episode: LibraryEpisode, using model: AppModel) async {
        guard let file = file(for: episode) else { return }
        do {
            UIPasteboard.general.url = try await Self.link(for: file, on: model.backend(file.item.item.backend))
            message = "Link copied."
        } catch {
            message = error.localizedDescription
        }
    }

    func download(_ episode: LibraryEpisode, using model: AppModel) async {
        guard let episodeFile = file(for: episode) else { return }
        do {
            let file = try await Self.resolve(episodeFile, on: model.backend(episodeFile.item.item.backend))
            try await model.download(file, of: episodeFile.item.item)
            message = "Downloading \(episode.code). Progress is in the Downloads tab."
        } catch {
            message = error.localizedDescription
        }
    }

    /// nzbdav's link carries the WebDAV login or a signature; players and copied links cannot send headers.
    private nonisolated static func link(for file: EpisodeFile, on backend: (any LibraryBackend)?) async throws -> URL {
        guard let backend else { throw BackendError.api(message: "\(file.item.item.backend.displayName) is not set up.") }
        let resolved = try await resolve(file, on: backend)
        return try await backend.playbackURL(itemID: file.item.item.id, fileID: resolved.id)
    }

    /// A single-episode item listed without files: its largest video.
    private nonisolated static func resolve(_ file: EpisodeFile, on backend: (any LibraryBackend)?) async throws -> LibraryFile {
        if let known = file.file { return known }
        guard let backend else { throw BackendError.api(message: "\(file.item.item.backend.displayName) is not set up.") }
        let loaded = try await backend.item(file.item.item.id)
        let videos = loaded.files.filter { FileKind.isVideo($0.name) && !FileKind.isSample($0.name) }
        guard let largest = videos.max(by: { ($0.size ?? 0) < ($1.size ?? 0) }) else {
            throw BackendError.api(message: "\(file.item.item.name) has no video file yet.")
        }
        return largest
    }
}

/// Links for a playlist, a few at a time and kept in order. Failed ones are nil; the first error is reported.
@MainActor
enum LinkBatch {
    static func fetch(
        _ jobs: [@Sendable () async throws -> URL],
        progress: (Int) -> Void
    ) async -> (urls: [URL?], failure: String?) {
        var urls = [URL?](repeating: nil, count: jobs.count)
        var failure: String?
        var done = 0
        await withTaskGroup(of: (Int, Result<URL, any Error>).self) { group in
            var next = 0
            func addNext() {
                guard next < jobs.count else { return }
                let index = next
                let job = jobs[index]
                next += 1
                group.addTask {
                    do { return (index, .success(try await job())) }
                    catch { return (index, .failure(error)) }
                }
            }
            // Debrid APIs rate-limit; four at a time keeps a season quick without bursting.
            for _ in 0..<4 { addNext() }
            for await (index, result) in group {
                switch result {
                case .success(let url): urls[index] = url
                case .failure(let error): failure = failure ?? error.localizedDescription
                }
                done += 1
                progress(done)
                addNext()
            }
        }
        return (urls, failure)
    }
}

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

/// "Preparing 3 of 24…" while links for a playlist are fetched.
struct PreparingBadge: View {
    let progress: (done: Int, total: Int)?

    var body: some View {
        if let progress {
            HStack(spacing: 8) {
                ProgressView()
                Text(progress.total > 1 ? "Preparing \(progress.done) of \(progress.total)…" : "Preparing…")
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
        }
    }
}

extension EpisodeFile {
    /// "TorBox · 1080p · 1.2 GB" for the version menu.
    var versionLabel: String {
        var parts = [item.item.backend.displayName]
        if let resolution { parts.append(resolution) }
        if let size { parts.append(size.formatted(.byteCount(style: .file))) }
        if !isReady { parts.append(item.item.status.label) }
        return parts.joined(separator: " · ")
    }
}
