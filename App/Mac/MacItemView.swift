import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// A library title, book, game or single release as a page: its cover and facts (Play for a movie), then its releases
/// (`MacHeldReleases`). The toolbar holds the title's own actions: Watchlist, Wrong title?, Find other releases,
/// Refresh, Delete.
struct MacItemView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    let target: MacRouter.LibraryTarget

    @State private var pendingDelete: [ShelfItem] = []
    @State private var message: String?
    /// Plays a movie's biggest release (`SeriesModel.playMovie`).
    @State private var playback = SeriesModel()
    /// "Wrong title?" and its book, album and game twins.
    @State private var isPickingMatch = false

    /// The releases still in the library: a deleted one leaves the page once the library is listed again.
    private var items: [ShelfItem] {
        let held = Set(model.library.items.map(\.id))
        return target.info.items.filter { held.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            MacHeldReleases(items: items)
        }
        .overlay(alignment: .bottom) { PreparingBadge(progress: playback.preparing) }
        .navigationTitle(target.info.name)
        .toolbar { toolbar }
        .sheet(isPresented: $isPickingMatch) { matchPicker.frame(minWidth: 460, minHeight: 520) }
        .modifier(LibraryActionDialogs(pendingDelete: $pendingDelete, message: $message))
    }

    private var actions: MacLibraryActions {
        .standard(model: model, report: { message = $0 }, confirmDelete: { pendingDelete = $0 })
    }

    // MARK: Toolbar

    /// The Watchlist bookmark; everything else is in the header's ⋯.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if case .title(let title) = target, let media = title.media {
            ToolbarItem {
                WatchlistButton(media: media)
            }
        }
    }

    /// The page's own items at the top of the header's ⋯.
    @ViewBuilder
    private var pageMenu: some View {
        if let label = matchLabel {
            Button(label, systemImage: "wand.and.stars") { isPickingMatch = true }
        }
        if let other = otherReleases {
            Button("Find Other Releases", systemImage: "magnifyingglass") { router.pushLibrary(other) }
        }
    }

    /// The book's, album's or game's releases from the indexers and plugins, over the Library (as the iPhone's
    /// "Find other releases").
    private var otherReleases: ReleaseTarget? {
        switch target {
        case .book(let book): book.book.map { .book($0, book.format) }
        case .album(let album): album.album.map { .album($0) }
        case .game(let game): game.game.map { .game($0) }
        case .title, .artist, .item: nil
        }
    }

    /// "Wrong title?", "Wrong book?"…: the target's metadata can be picked again (a single release has none).
    private var matchLabel: String? {
        switch target {
        case .title: "Wrong Title?"
        case .book: "Wrong Book?"
        case .album: "Wrong Album?"
        case .game: "Wrong Game?"
        case .artist, .item: nil
        }
    }

    @ViewBuilder
    private var matchPicker: some View {
        switch target {
        case .title(let title): MatchPickerSheet(title: title)
        case .book(let book): BookPickerSheet(book: book)
        case .album(let album): AlbumPickerSheet(album: album)
        case .game(let game): GamePickerSheet(game: game)
        case .artist, .item: EmptyView()
        }
    }

    // MARK: Header

    /// The page header (`MacPageHeader`): cover, name, facts, description, then one row of buttons: Play for a
    /// movie, Read or Play for a book, Download and ⋯ for every release.
    private var header: some View {
        let info = target.info
        return MacPageHeader(
            title: info.name, facts: info.subtitle, description: info.description,
            backdrop: info.backdrop, cover: info.cover, artworkWidth: info.ratio < 1 ? 150 : 190
        ) {
            CachedImage(url: info.cover) { Rectangle().fill(.quaternary) }
                .aspectRatio(info.ratio, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 6))
        } badges: {
            ForEach(Array(Set(items.map(\.item.backend))).sorted { $0.rawValue < $1.rawValue }, id: \.self) { BackendBadge(backend: $0) }
        } buttons: {
            if case .title(let title) = target, title.type == .movie {
                Button("Play", systemImage: "play.fill") {
                    Task { await playback.playMovie(title, using: model) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(playback.preparing != nil)
            }
            if case .book(let book) = target {
                MacBookActions(book: book)
            }
            if !items.isEmpty { MacItemsButtons(items: items, actions: actions) { pageMenu } }
        } notes: {
            if case .title(let title) = target, title.type == .movie {
                MacReviewSection(title: title, media: title.media)
            }
            if let message = playback.message {
                Text(message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

// MARK: - What a target shows

/// A target's page: its name, facts, description, cover, the cover's shape and its releases.
private struct TargetInfo {
    let name: String
    let subtitle: String?
    let description: String?
    let cover: URL?
    /// Width ÷ height of the cover.
    let ratio: CGFloat
    /// A movie's wide image behind the header.
    var backdrop: URL? = nil
    let items: [ShelfItem]
}

private extension MacRouter.LibraryTarget {
    var info: TargetInfo {
        switch self {
        case .title(let title):
            TargetInfo(name: title.name, subtitle: facts([title.year, title.coverage]),
                       description: title.media?.description, cover: title.media?.poster,
                       ratio: 2 / 3, backdrop: title.media?.background, items: title.items)
        case .book(let book):
            TargetInfo(name: book.name,
                       subtitle: facts([book.author, book.year, book.format == .audiobook ? "Audiobook" : "Ebook"]),
                       description: book.book?.description, cover: book.book?.cover,
                       ratio: book.format.coverRatio, items: book.items)
        case .album(let album):
            TargetInfo(name: album.name, subtitle: facts([album.artist, album.year]),
                       description: nil, cover: album.album?.cover, ratio: 1, items: album.items)
        case .artist(let artist):
            TargetInfo(name: artist.name,
                       subtitle: artist.albums.count == 1 ? "1 album" : "\(artist.albums.count) albums",
                       description: nil, cover: artist.cover, ratio: 1,
                       items: artist.albums.flatMap(\.items))
        case .game(let game):
            TargetInfo(name: game.name,
                       subtitle: facts([game.year] + game.platforms.prefix(4).map { Optional($0.displayName) }),
                       description: game.game?.summary, cover: game.cover, ratio: 3 / 4, items: game.items)
        case .item(let item):
            TargetInfo(name: item.name,
                       subtitle: facts([item.item.backend.displayName, item.item.size.map { $0.formatted(.byteCount(style: .file)) }]),
                       description: nil, cover: nil, ratio: 2 / 3, items: [item])
        }
    }

    /// "2019 · Complete" style line: the parts that exist, joined; nil when none does.
    private func facts(_ parts: [String?]) -> String? {
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }
}
