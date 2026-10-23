import DoveAppCore
import DoveKit
import SwiftUI

struct ArtistRoute: Hashable {
    let id: String
}

struct LibraryAlbumRoute: Hashable {
    let id: String
}

/// Play and Shuffle for some albums in Dove's player, with what went wrong under them.
struct MusicPlayButtons: View {
    @Environment(AppModel.self) private var model
    let albums: [AlbumTitle]
    let title: String
    var cover: URL?
    @State private var preparing: Bool?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                button("Play", systemImage: "play.fill", shuffled: false)
                button("Shuffle", systemImage: "shuffle", shuffled: true)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func button(_ label: String, systemImage: String, shuffled: Bool) -> some View {
        Button {
            preparing = shuffled
            message = nil
            Task {
                message = await model.playMusic(albums, title: title, cover: cover, shuffled: shuffled)
                preparing = nil
            }
        } label: {
            HStack {
                if preparing == shuffled { ProgressView() } else { Image(systemName: systemImage) }
                Text(label)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(preparing != nil)
    }
}

struct AlbumCard: View {
    let album: AlbumTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                AlbumCover(title: album.name, artist: album.artist, url: album.album?.cover)
                LibraryStatusMark(status: album.status, count: album.items.count).padding(5)
            }
            Text(album.name).font(.caption.weight(.medium)).lineLimit(1)
            HStack(spacing: 3) {
                if let year = album.year { Text(year).font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 2)
                ForEach(album.backends, id: \.self) { BackendBadge(backend: $0) }
            }
        }
    }
}

/// One artist's albums in the library.
struct ArtistView: View {
    @Environment(AppModel.self) private var model
    let artistID: String
    @State private var fixingAlbum: AlbumTitle?

    private var artist: ArtistShelf? { model.library.artist(id: artistID) }

    var body: some View {
        ScrollView {
            if let artist {
                MusicPlayButtons(albums: artist.albums, title: artist.name, cover: artist.cover)
                    .padding([.horizontal, .top])
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], alignment: .leading, spacing: 16) {
                    ForEach(artist.albums) { album in
                        NavigationLink(value: LibraryAlbumRoute(id: album.id)) {
                            AlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Wrong album?", systemImage: "magnifyingglass") { fixingAlbum = album }
                        }
                    }
                }
                .padding()
            } else {
                ContentUnavailableView("Not in your library anymore", systemImage: "tray")
            }
        }
        .navigationTitle(artist?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $fixingAlbum) { AlbumPickerSheet(album: $0) }
    }
}

/// One album across services: cover, its tracks, its releases, and other releases from the indexers.
struct LibraryAlbumView: View {
    @Environment(AppModel.self) private var model
    let albumID: String
    @State private var isFixingMatch = false
    @State private var tracks: [AlbumTrack]?
    @State private var showTracks = false
    @State private var trackMessage: String?

    private var album: AlbumTitle? { model.library.album(id: albumID) }

    var body: some View {
        List {
            if let album {
                Section {
                    header(album)
                    MusicPlayButtons(albums: [album], title: album.name, cover: album.album?.cover)
                    if let tracks, !tracks.isEmpty {
                        DisclosureGroup("\(tracks.count) tracks", isExpanded: $showTracks) {
                            ForEach(tracks) { track in
                                // A tap plays the album from this track (its file found by title, else position).
                                Button {
                                    trackMessage = nil
                                    Task { trackMessage = await model.playMusic([album], title: album.name, cover: album.album?.cover, start: .track(track)) }
                                } label: {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("\(track.position)").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 24, alignment: .trailing)
                                        Text(track.title)
                                        Spacer()
                                        if let duration = track.duration {
                                            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                                .monospacedDigit()
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .font(.subheadline)
                                }
                                .tint(.primary)
                            }
                            if let trackMessage { Text(trackMessage).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    if let summary = album.album {
                        NavigationLink(value: AlbumRoute(album: summary)) {
                            Label("Find other releases", systemImage: "magnifyingglass")
                        }
                    }
                    Button("Wrong album?", systemImage: "arrow.triangle.2.circlepath") { isFixingMatch = true }
                        .font(.footnote)
                }
                Section("Releases") {
                    ForEach(album.items) { item in
                        NavigationLink(value: item) { ShelfItemRow(item: item) }
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    Task { await model.library.delete(item, using: model) }
                                }
                            }
                    }
                }
            } else {
                ContentUnavailableView("Not in your library anymore", systemImage: "tray")
            }
        }
        .navigationTitle(album?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isFixingMatch) {
            if let album { AlbumPickerSheet(album: album) }
        }
        .task(id: album?.album?.id) {
            guard let summary = album?.album else { return }
            tracks = try? await model.musicMetadata.tracks(of: summary)
        }
    }

    private func header(_ album: AlbumTitle) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AlbumCover(title: album.name, artist: album.artist, url: album.album?.cover)
                .frame(width: 120)
            VStack(alignment: .leading, spacing: 6) {
                Text(album.name).font(.title3.bold())
                if let artist = album.artist { Text(artist).font(.subheadline) }
                HStack(spacing: 6) {
                    if let type = album.album?.type { Text(type) }
                    if let year = album.year { Text(year) }
                    if album.size > 0 { Text(album.size.formatted(.byteCount(style: .file))) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(album.backends, id: \.self) { BackendBadge(backend: $0) }
                }
                if album.album == nil {
                    Text("No album found yet. MusicBrainz is searched on refresh.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

