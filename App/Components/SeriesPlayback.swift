import DoveAppCore
import DoveKit
import SwiftUI

// Series playback shared by the iPhone's season screens and the Mac's series page: the episodes of a title matched to
// its files, the version picked per episode, links for a playlist, and what plays or downloads them.

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

    /// The episode's playable link (its file resolved first), for the platform's pasteboard; nil when nothing holds it.
    func episodeLink(_ episode: LibraryEpisode, using model: AppModel) async throws -> URL? {
        guard let file = file(for: episode) else { return nil }
        return try await Self.link(for: file, on: model.backend(file.item.item.backend))
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
    nonisolated static func link(for file: EpisodeFile, on backend: (any LibraryBackend)?) async throws -> URL {
        guard let backend else { throw BackendError.api(message: "\(file.item.item.backend.displayName) is not set up.") }
        let resolved = try await resolve(file, on: backend)
        return try await backend.playbackURL(itemID: file.item.item.id, fileID: resolved.id)
    }

    /// A single-episode item listed without files: its largest video.
    nonisolated static func resolve(_ file: EpisodeFile, on backend: (any LibraryBackend)?) async throws -> LibraryFile {
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
    var versionLabel: String { label(withSize: true) }

    /// The same without the size, for tables that show it in their own column.
    func label(withSize: Bool) -> String {
        var parts = [item.item.backend.displayName]
        if let resolution { parts.append(resolution) }
        if withSize, let size { parts.append(size.formatted(.byteCount(style: .file))) }
        if !isReady { parts.append(item.item.status.label) }
        return parts.joined(separator: " · ")
    }
}
