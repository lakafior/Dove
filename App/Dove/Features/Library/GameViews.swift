import DoveAppCore
import DoveKit
import SwiftUI

/// A game of the library, by `GameTitle.id`.
struct LibraryGameRoute: Hashable {
    let id: String
}

/// One game in the library: what IGDB or Wikidata says about it, its releases, and a way to find others.
struct LibraryGameView: View {
    @Environment(AppModel.self) private var model
    let gameID: String
    @State private var isFixingMatch = false
    @State private var showSummary = false
    /// One of its releases: "Wrong game?" gives the game a new ID, and the screen follows its releases there.
    @State private var anchorItem: ShelfItem.ID?

    private var game: GameTitle? {
        model.library.game(id: gameID)
            ?? anchorItem.flatMap { id in model.library.games.first { $0.items.contains { $0.id == id } } }
    }

    var body: some View {
        List {
            if let game {
                Section {
                    header(game)
                    if let summary = game.game?.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .lineLimit(showSummary ? nil : 4)
                            .onTapGesture { withAnimation { showSummary.toggle() } }
                    }
                    if let summary = game.game {
                        NavigationLink(value: GameRoute(game: summary)) {
                            Label("Find other releases", systemImage: "magnifyingglass")
                        }
                    }
                    if !game.isCollection {
                        Button("Wrong game?", systemImage: "arrow.triangle.2.circlepath") { isFixingMatch = true }
                            .font(.footnote)
                    }
                }
                Section("Releases") {
                    ForEach(game.items) { item in
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
        .navigationTitle(game?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isFixingMatch) {
            if let game { GamePickerSheet(game: game) }
        }
        .onAppear { if anchorItem == nil { anchorItem = game?.items.first?.id } }
    }

    private func header(_ game: GameTitle) -> some View {
        HStack(alignment: .top, spacing: 12) {
            GameCover(url: game.cover, title: game.name, isCollection: game.isCollection)
                .frame(width: 110)
            VStack(alignment: .leading, spacing: 6) {
                Text(game.name).font(.title3.bold())
                HStack(spacing: 6) {
                    if let year = game.year { Text(year) }
                    if game.size > 0 { Text(game.size.formatted(.byteCount(style: .file))) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !game.platforms.isEmpty {
                    Text(game.platforms.map(\.displayName).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let genres = game.game?.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    ForEach(game.backends, id: \.self) { BackendBadge(backend: $0) }
                }
                if let link = game.game?.link, let summary = game.game {
                    Link(summary.sourceName(plugins: model.plugins.manifests()), destination: link).font(.caption)
                }
                if game.isCollection {
                    Text("A collection of games: not looked up.").font(.footnote).foregroundStyle(.secondary)
                } else if game.game == nil {
                    Text(model.igdbCredentials == nil
                         ? "No game found yet. Wikidata is searched on refresh; IGDB (Settings › Games) finds more."
                         : "No game found yet. IGDB and Wikidata are searched on refresh.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

