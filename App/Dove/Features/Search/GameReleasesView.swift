import DoveAppCore
import DoveKit
import SwiftUI

/// A game picked from the Games search.
struct GameRoute: Hashable {
    let game: GameSummary
}

/// One game from IGDB or Wikidata: cover, facts, description, then the indexers' releases of it (`t=search` with
/// the title in the games categories; Newznab has no game search), this game's first, with platform chips; the
/// plugins' rows on their own tab.
struct GameReleasesView: View {
    @Environment(AppModel.self) private var model
    let route: GameRoute
    @State private var releases: ReleaseList
    @State private var pluginSearch = PluginSearch()
    @State private var tab = ResultsTab.sources
    @State private var showSummary = false
    @State private var siteSearch: BrowserRequest?

    init(route: GameRoute) {
        self.route = route
        _releases = State(initialValue: ReleaseList(game: route.game))
    }

    private var game: GameSummary { route.game }

    var body: some View {
        List {
            Section {
                header
                if let summary = game.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .lineLimit(showSummary ? nil : 4)
                        .onTapGesture { withAnimation { showSummary.toggle() } }
                }
                ForEach(model.plugins.browsers(for: .games), id: \.id) { call in
                    if let url = call.browseURL(for: game.indexerQuery) {
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
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SourcesMenu(category: .games, refresh: releases.isSearching) }
        }
        .task { if releases.isEmpty, releases.message == nil { search() } }
        .onChange(of: model.sourceSelection) { search() }
        .refreshable { search() }
        .sheet(item: $siteSearch) { SiteBrowserView(start: $0.url, category: .games) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            GameCover(url: game.cover)
                .frame(width: 100, height: 133)
            VStack(alignment: .leading, spacing: 6) {
                Text(game.title).font(.headline)
                HStack(spacing: 6) {
                    if let year = game.year { Text(String(year)) }
                    if let type = game.type, !game.isMainGame { Text(type) }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if !game.platforms.isEmpty {
                    Text(game.platforms.map(\.displayName).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !game.genres.isEmpty {
                    Text(game.genres.prefix(3).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let link = game.link {
                    Link(game.sourceName(plugins: model.plugins.manifests()), destination: link).font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func search() {
        releases.search(.text(game.indexerQuery, category: .games), in: .games, model: model)
        pluginSearch.search(game.indexerQuery, category: .games, calls: model.plugins.calls(.search, category: .games))
    }
}

