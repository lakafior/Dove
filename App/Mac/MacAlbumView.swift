import DoveAppCore
import DoveKit
import SwiftUI

/// One album as a page: cover and facts, Play, Shuffle, Download and ⋯, then its tracks as a table (double-click plays
/// from a track) or, in the Releases tab, the releases with their files and actions (`MacHeldReleases`). Pushed over the Library from an artist's page
/// or a Music search, so the artist shows as the breadcrumb.
struct MacAlbumView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    /// The album as the Library listed it when it was opened; the live one is read from the library below.
    let album: AlbumTitle

    @State private var tracks: [AlbumTrack] = []
    @State private var loadingTracks = false
    @State private var trackMessage: String?
    @AppStorage("macAlbumTab") private var tab: PageTab = .contents
    @State private var isPickingMatch = false
    @State private var pendingDelete: [ShelfItem] = []
    @State private var message: String?

    private var actions: MacLibraryActions {
        .standard(model: model, report: { message = $0 }, confirmDelete: { pendingDelete = $0 })
    }
    @State private var selection = Set<AlbumTrack.ID>()

    /// The album as the library holds it now; nil once it has left the library.
    private var current: AlbumTitle? { model.library.album(id: album.id) }

    var body: some View {
        if let current {
            VStack(alignment: .leading, spacing: 0) {
                header(current)
                PageTabPicker(tab: $tab, contents: "Tracks", releases: current.items.count)
                Group {
                    switch tab {
                    case .contents: tracksSection(current).padding(.horizontal, 24).padding(.bottom, 16)
                    case .releases: MacHeldReleases(items: current.items)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(current.artist.map { "\($0) › \(current.name)" } ?? current.name)
            .sheet(isPresented: $isPickingMatch) {
                AlbumPickerSheet(album: current).frame(minWidth: 460, minHeight: 520)
            }
            .modifier(LibraryActionDialogs(pendingDelete: $pendingDelete, message: $message))
            .task(id: current.album?.id) { await loadTracks(current) }
        } else {
            ContentUnavailableView("Not in your library anymore", systemImage: "tray")
        }
    }

    private func header(_ album: AlbumTitle) -> some View {
        let facts = [album.album?.type, album.year, album.size > 0 ? album.size.formatted(.byteCount(style: .file)) : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return MacPageHeader(title: album.name, subtitle: album.artist, facts: facts.isEmpty ? nil : facts,
                             cover: album.album?.cover, artworkWidth: 190) {
            AlbumCover(title: album.name, artist: album.artist, url: album.album?.cover, cornerRadius: 8)
        } badges: {
            ForEach(album.backends, id: \.self) { BackendBadge(backend: $0) }
        } buttons: {
            MacMusicPlayButtons(albums: [album], title: album.name, cover: album.album?.cover)
            MacItemsButtons(items: album.items, actions: actions) {
                if let summary = album.album {
                    Button("Find Other Releases", systemImage: "magnifyingglass") { router.pushLibrary(ReleaseTarget.album(summary)) }
                }
                Button("Wrong Album?", systemImage: "wand.and.stars") { isPickingMatch = true }
            }
        } notes: {
            if album.album == nil {
                Text("No album found yet. MusicBrainz is searched on refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The album's tracks as a table, in order; "Play from This Track" or a double-click starts there.
    private func tracksSection(_ album: AlbumTitle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if tracks.isEmpty {
                Text(loadingTracks ? "Loading the track list…" : "No track list for this album yet.")
                    .foregroundStyle(.secondary)
            } else {
                Table(tracks, selection: $selection) {
                    TableColumn("#") { track in
                        Text("\(track.position)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(36)
                    TableColumn("Title") { track in
                        Text(track.title).lineLimit(1)
                    }
                    .width(min: 200, ideal: 380)
                    TableColumn("Duration") { track in
                        if let duration = track.duration {
                            Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                        }
                    }
                    .width(min: 60, ideal: 80)
                }
                .contextMenu(forSelectionType: AlbumTrack.ID.self) { ids in
                    if let track = tracks.first(where: { ids.contains($0.id) }) {
                        Button("Play from This Track", systemImage: "play") { playTrack(track, of: album) }
                    }
                } primaryAction: { ids in
                    if let track = tracks.first(where: { ids.contains($0.id) }) { playTrack(track, of: album) }
                }
                .frame(maxHeight: .infinity)
            }
            if let trackMessage {
                Text(trackMessage).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The album's track list from MusicBrainz or the catalog (`MusicMetadata.tracks`); empty when neither names one.
    private func loadTracks(_ album: AlbumTitle) async {
        tracks = []
        guard let summary = album.album else { return }
        loadingTracks = true
        defer { loadingTracks = false }
        tracks = (try? await model.musicMetadata.tracks(of: summary)) ?? []
    }

    private func playTrack(_ track: AlbumTrack, of album: AlbumTitle) {
        trackMessage = nil
        Task {
            trackMessage = await model.playMusic([album], title: album.name, cover: album.album?.cover, start: .track(track))
        }
    }
}
