import DoveKit
import Foundation

extension AppModel {
    /// What to play first.
    public enum MusicStart {
        case beginning
        /// A track of the first album, as the metadata lists it (matched to its file by title, else position).
        case track(AlbumTrack)
        /// A file of the first album's release.
        case file(LibraryFile.ID)
    }

    /// Plays albums in Dove's player: an album, an artist's albums, the whole library. The first album (a random
    /// one when shuffled) starts as soon as its files are known; the others join the queue as theirs arrive
    /// (Offcloud and Real-Debrid list items without files, so each album may cost one detail call). Nothing is
    /// saved: music starts where it is told to. Returns why nothing could play, or nil once something does.
    public func playMusic(_ albums: [AlbumTitle], title: String, cover: URL? = nil, start: MusicStart = .beginning, shuffled: Bool = false) async -> String? {
        guard !albums.isEmpty else { return "Nothing to play." }
        var order = albums
        if shuffled, case .beginning = start { order.shuffle() }
        var refusal: String?
        var first: (index: Int, entries: [AudiobookPlayer.Session.Entry])?
        for (index, album) in order.enumerated() {
            switch await musicEntries(for: album) {
            case .success(let entries):
                first = (index, entries)
            case .failure(let reason):
                refusal = refusal ?? reason.message
                continue
            }
            break
        }
        guard let first else { return refusal ?? "No release of this music is ready on a service yet." }

        var startIndex = 0
        switch start {
        case .track(let track):
            startIndex = MusicTracks.index(of: track, in: first.entries.map(\.track), artist: order[first.index].artist) ?? 0
        case .file(let fileID):
            startIndex = first.entries.firstIndex { $0.track.fileID == fileID } ?? 0
        case .beginning:
            // Shuffled, the first track is a random one too, not the album's opener.
            if shuffled { startIndex = Int.random(in: first.entries.indices) }
        }
        let session = AudiobookPlayer.Session(music: "music:\(title)", title: title, cover: cover ?? order[first.index].album?.cover, queue: first.entries)
        audiobook.startMusic(session, at: startIndex, shuffled: shuffled)
        audiobook.isPresented = true

        // The rest, one album after another, each joining the queue as soon as its files are known (the player
        // places them at random when shuffle is on). Stops when something else starts playing.
        let rest = Array(order[(first.index + 1)...])
        let sessionID = session.id
        Task {
            for album in rest {
                guard audiobook.session?.id == sessionID else { return }
                if case .success(let entries) = await musicEntries(for: album) {
                    audiobook.append(entries, to: sessionID)
                }
            }
        }
        return nil
    }

    /// One album's tracks from its best release: ready, files known (or fetched), playable on iPhone.
    private func musicEntries(for album: AlbumTitle) async -> Result<[AudiobookPlayer.Session.Entry], AudiobookTracks.Refusal> {
        var refusal: AudiobookTracks.Refusal = .noAudio
        // Releases whose files are already listed first: no detail call.
        let ready = album.items.filter { $0.item.status == .ready }.sorted { !$0.item.files.isEmpty && $1.item.files.isEmpty }
        for shelfItem in ready {
            var item = shelfItem.item
            if item.files.isEmpty, let backend = backend(item.backend) {
                guard let detail = try? await backend.item(item.id) else { continue }
                item = detail
            }
            switch AudiobookTracks.tracks(in: item.files) {
            case .success(let tracks):
                let artist = album.artist
                return .success(tracks.map { track in
                    AudiobookPlayer.Session.Entry(
                        item: item,
                        track: track,
                        title: MusicTracks.title(of: track.path, artist: artist),
                        artist: artist,
                        album: album.name,
                        cover: album.album?.cover
                    )
                })
            case .failure(let reason):
                refusal = reason
            }
        }
        return .failure(refusal)
    }
}
