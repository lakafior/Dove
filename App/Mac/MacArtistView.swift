import DoveAppCore
import DoveKit
import SwiftUI

/// An artist's albums as a page: the newest album's cover, the name, a summary line (albums, tracks where the files list
/// them, size), and Play and Shuffle over all of them. The albums come as covers (a click opens the album over the
/// Library) or as a table. Shown over the Library (`MacLibraryStack`), like the iPhone's `ArtistView`.
struct MacArtistView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    /// The artist as the Library listed it when it was opened; the live one is read from the library below.
    let artist: ArtistShelf

    @AppStorage(LibraryViewMode.storageKey) private var mode: LibraryViewMode = .icons
    @State private var selection = Set<AlbumTitle.ID>()
    @State private var pendingDelete: [ShelfItem] = []
    @State private var message: String?

    private var actions: MacLibraryActions {
        .standard(model: model, report: { message = $0 }, confirmDelete: { pendingDelete = $0 })
    }

    /// The artist as the library holds it now; nil once it has left the library.
    private var current: ArtistShelf? { model.library.artist(id: artist.id) }

    var body: some View {
        if let current {
            Group {
                if mode == .icons {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            header(current)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], alignment: .leading, spacing: 24) {
                                ForEach(current.albums) { album in
                                    AlbumTile(album: album)
                                        .contentShape(.rect)
                                        .onTapGesture { router.pushLibrary(MacRouter.LibraryTarget.album(album)) }
                                        .contextMenu { albumMenu([album]) }
                                }
                            }
                            .padding([.horizontal, .bottom], 24)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        header(current)
                        albumTable(current).padding([.horizontal, .bottom], 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .navigationTitle(current.name)
            .toolbar {
                // Where the Finder has it: first in the trailing group, before the actions and search.
                ToolbarItem(placement: .primaryAction) {
                    ViewModePicker(mode: $mode)
                }
            }
            .modifier(LibraryActionDialogs(pendingDelete: $pendingDelete, message: $message))
        } else {
            ContentUnavailableView("Not in your library anymore", systemImage: "tray")
        }
    }

    private func header(_ artist: ArtistShelf) -> some View {
        MacPageHeader(title: artist.name, facts: summary(artist), cover: artist.cover, artworkWidth: 180) {
            AlbumCover(title: artist.name, artist: nil, url: artist.cover, cornerRadius: 8)
        } badges: {
            ForEach(Array(Set(artist.albums.flatMap(\.backends))).sorted { $0.rawValue < $1.rawValue }, id: \.self) {
                BackendBadge(backend: $0)
            }
        } buttons: {
            MacMusicPlayButtons(albums: artist.albums, title: artist.name, cover: artist.cover)
            MacItemsButtons(items: artist.albums.flatMap(\.items), actions: actions)
        } notes: {
            EmptyView()
        }
    }

    /// An album's (or the selection's) menu: Open, Play, Shuffle, Copy Name and every action of the Library's cards.
    private func albumMenu(_ albums: [AlbumTitle]) -> some View {
        actions.targetMenu(albums.map { .album($0) }) { router.pushLibrary($0) }
    }

    /// "3 albums · 27 tracks · 2.1 GB"; the tracks count only when the files list them.
    private func summary(_ artist: ArtistShelf) -> String {
        let albums = artist.albums.count == 1 ? "1 album" : "\(artist.albums.count) albums"
        let tracks = Self.trackCount(artist.albums)
        let size = artist.albums.reduce(Int64(0)) { $0 + $1.size }
        var parts = [albums]
        if tracks > 0 { parts.append(tracks == 1 ? "1 track" : "\(tracks) tracks") }
        if size > 0 { parts.append(size.formatted(.byteCount(style: .file))) }
        return parts.joined(separator: " · ")
    }

    /// Audio files listed by the album's releases (zero when the services list none).
    static func trackCount(_ albums: [AlbumTitle]) -> Int {
        albums.reduce(0) { total, album in
            total + album.items.reduce(0) { count, item in
                count + item.item.files.filter { AudiobookTracks.playableExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }.count
            }
        }
    }

    private func albumTable(_ artist: ArtistShelf) -> some View {
        Table(artist.albums, selection: $selection) {
            TableColumn("Album") { album in
                Text(album.name).lineLimit(1)
            }
            .width(min: 200, ideal: 320)
            TableColumn("Year") { album in
                Text(album.year ?? "–").monospacedDigit()
            }
            .width(min: 50, ideal: 60)
            TableColumn("Tracks") { album in
                let count = Self.trackCount([album])
                Text(count > 0 ? "\(count)" : "–").monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Format") { album in
                let formats = Set(album.items.flatMap { MusicFileFormat.formats(in: $0.name) }).sorted()
                Text(formats.isEmpty ? "–" : formats.map(\.displayName).joined(separator: ", ")).lineLimit(1)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Size") { album in
                Text(album.size > 0 ? album.size.formatted(.byteCount(style: .file)) : "–").monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Services") { album in
                HStack(spacing: 4) {
                    ForEach(album.backends, id: \.self) { BackendBadge(backend: $0) }
                }
            }
            .width(min: 90, ideal: 120)
        }
        .contextMenu(forSelectionType: AlbumTitle.ID.self) { ids in
            albumMenu(artist.albums.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let album = artist.albums.first(where: { ids.contains($0.id) }) {
                router.pushLibrary(MacRouter.LibraryTarget.album(album))
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Play and Shuffle for some albums in Dove's player, with what went wrong under them (`MusicPlayButtons` on the iPhone).
struct MacMusicPlayButtons: View {
    @Environment(AppModel.self) private var model
    let albums: [AlbumTitle]
    let title: String
    var cover: URL?
    /// The button being prepared: `false` for Play, `true` for Shuffle.
    @State private var preparing: Bool?
    @State private var message: String?

    var body: some View {
        Group {
            playButton("Play", systemImage: "play.fill", shuffled: false)
                .buttonStyle(.borderedProminent)
            playButton("Shuffle", systemImage: "shuffle", shuffled: true)
                .buttonStyle(.bordered)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }

    private func playButton(_ label: String, systemImage: String, shuffled: Bool) -> some View {
        Button {
            preparing = shuffled
            message = nil
            Task {
                message = await model.playMusic(albums, title: title, cover: cover, shuffled: shuffled)
                preparing = nil
            }
        } label: {
            HStack(spacing: 6) {
                if preparing == shuffled {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(label)
            }
            .frame(minWidth: 70)
        }
        .disabled(preparing != nil)
    }
}

/// An album on the artist's page: its cover, year and the services that hold it, rising under the pointer.
private struct AlbumTile: View {
    let album: AlbumTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                AlbumCover(title: album.name, artist: album.artist, url: album.album?.cover)
                LibraryStatusMark(status: album.status, count: album.items.count).padding(6)
            }
            Text(album.name).font(.callout.weight(.medium)).lineLimit(1)
            HStack(spacing: 4) {
                if let year = album.year { Text(year).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 2)
                ForEach(album.backends, id: \.self) { BackendBadge(backend: $0) }
            }
        }
        .hoverLift()
        .help(album.name)
    }
}
