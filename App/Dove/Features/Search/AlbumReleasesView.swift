import DoveAppCore
import DoveKit
import SwiftUI

/// An album picked from the Music search.
struct AlbumRoute: Hashable {
    let album: AlbumSummary
}

/// One album from MusicBrainz: cover, its tracks (asked when opened), then the indexers' releases of it
/// (`t=music` with album and artist where an indexer has it, else "artist album"), this album's first, and the
/// plugins' rows on their own tab.
struct AlbumReleasesView: View {
    @Environment(AppModel.self) private var model
    let route: AlbumRoute
    @State private var releases: ReleaseList
    @State private var pluginSearch = PluginSearch()
    @State private var tab = ResultsTab.sources
    @State private var tracks: [AlbumTrack]?
    @State private var tracksError: String?
    @State private var showTracks = false
    @State private var siteSearch: BrowserRequest?

    init(route: AlbumRoute) {
        self.route = route
        _releases = State(initialValue: ReleaseList(album: route.album))
    }

    private var album: AlbumSummary { route.album }
    private var words: String { [album.artist, album.searchTitle].compactMap { $0 }.joined(separator: " ") }

    var body: some View {
        List {
            Section {
                header
                tracksRow
                ForEach(model.plugins.browsers(for: .music), id: \.id) { call in
                    if let url = call.browseURL(for: words) {
                        Button("Search on \(call.manifest.name)", systemImage: "safari") { siteSearch = BrowserRequest(url: url) }
                    }
                }
            }
            if tab == .plugins {
                PluginResultsSections(search: pluginSearch, showsState: true)
            } else {
                if releases.isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }
                if let message = releases.message {
                    Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
                if !releases.isEmpty {
                    ReleaseListSection(list: releases, title: "Releases")
                }
            }
        }
        .resultsTabs($tab, sources: "Releases", count: releases.isSearching ? nil : releases.visible.count, plugins: pluginSearch)
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SourcesMenu(category: .music, refresh: releases.isSearching) }
        }
        .task { if releases.isEmpty, releases.message == nil { search() } }
        .task { await loadTracks() }
        .onChange(of: model.sourceSelection) { search() }
        .refreshable { search() }
        .sheet(item: $siteSearch) { SiteBrowserView(start: $0.url, category: .music) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            CachedImage(url: album.cover) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .overlay { Image(systemName: "music.note").font(.title).foregroundStyle(.secondary) }
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(album.title).font(.headline)
                if let artist = album.artist {
                    Text(artist).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    if let year = album.year { Text(String(year)) }
                    if let type = album.type { Text(type) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let link = album.link {
                    Link(album.sourceName(plugins: model.plugins.manifests()), destination: link).font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Collapsed: a popular album's releases matter more than its track list.
    @ViewBuilder
    private var tracksRow: some View {
        if let tracks, !tracks.isEmpty {
            DisclosureGroup("\(tracks.count) tracks\(totalDuration(tracks).map { " · \($0)" } ?? "")", isExpanded: $showTracks) {
                let discs = Set(tracks.map(\.disc)).count
                ForEach(tracks) { track in
                    HStack(alignment: .firstTextBaseline) {
                        Text(discs > 1 ? "\(track.disc).\(track.position)" : "\(track.position)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 24, alignment: .trailing)
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
            }
        } else if let tracksError {
            Text(tracksError).font(.footnote).foregroundStyle(.secondary)
        } else if tracks == nil, album.releaseID != nil || album.catalogID != nil || !album.id.hasPrefix("mb:") {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading tracks…").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func totalDuration(_ tracks: [AlbumTrack]) -> String? {
        let durations = tracks.compactMap(\.duration)
        guard durations.count == tracks.count else { return nil }
        return Duration.seconds(durations.reduce(0, +)).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private func loadTracks() async {
        guard tracks == nil else { return }
        do {
            tracks = try await model.musicMetadata.tracks(of: album)
        } catch {
            tracksError = error.localizedDescription
        }
    }

    private func search() {
        releases.search(.album(title: album.searchTitle, artist: album.artists.first), in: .music, model: model)
        pluginSearch.search(words, category: .music, album: album, calls: model.plugins.calls(.search, category: .music))
    }
}

