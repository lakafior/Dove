import DoveAppCore
import DoveKit
import SwiftUI

/// Under the start page's search field: the services at a glance, what is in progress, what was added lately, the
/// library's shelves and recent searches. Everything comes from what is already loaded; nothing here costs a call.
struct MacHomeSections: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    let layout: HomeLayout
    let recentSearches: [HomeModel.RecentSearch]
    let onSearch: (HomeModel.RecentSearch) -> Void
    let onForget: (HomeModel.RecentSearch) -> Void
    let onForgetAll: () -> Void
    /// The pointer rests on a poster: its backdrop (or cover) goes behind the field.
    let onHoverBackdrop: (URL?) -> Void

    @State private var message: String?

    private var library: LibraryModel { model.library }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            services
            inProgress
            newEpisodes
            recentlyAdded
            watchlist
            shelves
            recent
        }
        .frame(maxWidth: layout.contentWidth, alignment: .leading)
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }

    // MARK: Services

    /// Set-up services as capsules: light, name, days left. A click opens the service's page.
    @ViewBuilder
    private var services: some View {
        let backends = (BackendID.services + [.calibre]).filter(model.isConfigured)
        if !backends.isEmpty {
            FlowRow(spacing: 8) {
                ForEach(backends, id: \.self) { backend in
                    Button { router.selection = .service(backend) } label: {
                        HStack(spacing: 6) {
                            StatusLight(color: model.services.light(backend))
                            Text(backend.displayName).fontWeight(.medium)
                            if let notice = notice(backend) { Text(notice.text).foregroundStyle(notice.color) }
                        }
                        .scaledFont(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .help(model.services.accountSummary(backend) ?? backend.displayName)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Only what needs attention: offline, free or expired (red), under 30 days left (orange). The full account is in
    /// the capsule's help.
    private func notice(_ backend: BackendID) -> (text: String, color: Color)? {
        if case .offline = model.services.health(of: backend) { return ("Offline", .red) }
        guard let account = model.services.accounts[backend] else { return nil }
        guard account.isPremium else { return ("Free", .red) }
        if let end = account.premiumUntil, end < .now { return ("Expired", .red) }
        guard let days = account.daysLeft(), days < 30 else { return nil }
        return ("\(days) d", .orange)
    }

    // MARK: In progress

    @ViewBuilder
    private var inProgress: some View {
        let downloads = model.downloads.records.filter { $0.state == .downloading }
        let onServices = library.items.filter { LibraryFilter.Status(of: $0.item.status) == .active }
        if !downloads.isEmpty || !onServices.isEmpty {
            HomeSection("In progress", action: ("Downloads", { router.selection = downloads.isEmpty ? .onServices : .downloads })) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(downloads.prefix(6)) { record in
                        ProgressCard(
                            title: record.name, place: "To \(record.destination.displayName)", badge: record.backend,
                            progress: record.progress, detail: record.totalBytes.map {
                                "\(record.bytesWritten.formatted(.byteCount(style: .file))) of \($0.formatted(.byteCount(style: .file)))"
                            }
                        )
                        .onTapGesture { router.selection = .downloads }
                    }
                    ForEach(onServices.prefix(6)) { item in
                        ProgressCard(
                            title: item.name, place: "On \(item.item.backend.displayName)", badge: item.item.backend,
                            progress: { if case .downloading(let value) = item.item.status { value } else { nil } }(),
                            detail: item.item.status.label
                        )
                        .onTapGesture { router.selection = .onServices }
                    }
                }
            }
        }
    }

    // MARK: New episodes

    @ViewBuilder
    private var newEpisodes: some View {
        let entries = model.review.episodeTitles(in: library.titles).filter { !$0.review.new.isEmpty }.prefix(15)
        if !entries.isEmpty {
            HomeSection("New episodes") {
                PosterRow {
                    ForEach(Array(entries), id: \.title.id) { entry in
                        PosterTile(url: entry.title.media?.poster, title: entry.title.name, subtitle: entry.review.episodeSummary,
                                       width: layout.posterHeight * 2 / 3)
                            .onTapGesture { open(entry.title) }
                            .onHover { if $0 { onHoverBackdrop(entry.title.media?.background ?? entry.title.media?.poster) } }
                            .contextMenu { itemMenu(entry.title.items) }
                    }
                }
            }
        }
    }

    // MARK: Recently added

    /// Everything the library got lately, of every kind, newest first.
    @ViewBuilder
    private var recentlyAdded: some View {
        let entries = recentEntries
        if !entries.isEmpty {
            HomeSection("Recently added", action: ("Library", { router.selection = .library(nil) })) {
                PosterRow {
                    ForEach(entries) { entry in
                        entry.card
                            // One height for every kind: square and box covers are wider, so names line up.
                            .frame(width: layout.posterHeight * entry.ratio)
                            .hoverLift()
                            .onTapGesture { open(entry) }
                            .onHover { if $0 { onHoverBackdrop(entry.backdrop) } }
                            .contextMenu { itemMenu(entry.items) }
                    }
                }
            }
        }
    }

    private var recentEntries: [RecentEntry] {
        let titles = library.titles.map(RecentEntry.title)
        let books = library.books.map(RecentEntry.book)
        let albums = library.albums.map(RecentEntry.album)
        let games = library.games.map(RecentEntry.game)
        return Array((titles + books + albums + games).sorted { $0.added > $1.added }.prefix(24))
    }

    // MARK: Watchlist

    @ViewBuilder
    private var watchlist: some View {
        let entries = Array(model.watchlist.list.entries.prefix(15))
        if !entries.isEmpty {
            HomeSection("Watchlist", action: ("All", { router.selection = .watchlist })) {
                PosterRow {
                    ForEach(entries) { entry in
                        PosterTile(url: entry.media.poster, title: entry.media.name,
                                   subtitle: model.watchlist.status(of: entry, using: model)?.label() ?? entry.media.releaseInfo,
                                   width: layout.posterHeight * 2 / 3)
                            .onTapGesture { router.show(.media(entry.media)) }
                            .onHover { if $0 { onHoverBackdrop(entry.media.background ?? entry.media.poster) } }
                            .contextMenu {
                                Button("Remove from Watchlist", systemImage: "bookmark.slash") { model.watchlist.remove(entry) }
                            }
                    }
                }
            }
        }
    }

    // MARK: Actions

    /// What the library holds opens the way the Library opens it (`MacRouter.openLibrary`), not as a search.
    private func open(_ title: LibraryTitle) {
        router.openLibrary(.title(title))
    }

    private func open(_ entry: RecentEntry) {
        switch entry {
        case .title(let title): router.openLibrary(.title(title))
        case .book(let book): router.openLibrary(.book(book))
        case .album(let album): router.openLibrary(.album(album))
        case .game(let game): router.openLibrary(.game(game))
        }
    }

    @ViewBuilder
    private func itemMenu(_ items: [ShelfItem]) -> some View {
        let ready = items.filter { item in
            guard !item.item.backend.isOnDevice else { return false }
            if case .ready = item.item.status { return true }
            return false
        }
        Button("Download", systemImage: "arrow.down.circle") {
            Task {
                var failures: [String] = []
                for item in ready {
                    do { try await model.downloadItem(item) } catch { failures.append(error.localizedDescription) }
                }
                if !failures.isEmpty { message = failures.joined(separator: "\n") }
            }
        }
        .disabled(ready.isEmpty)
    }

    // MARK: Shelves

    @ViewBuilder
    private var shelves: some View {
        let shelves = LibraryShelfSummary.all(in: library, showAdult: model.showAdult)
        if !shelves.isEmpty {
            HomeSection("Your library") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.shelfMinimum), spacing: 14)], spacing: 14) {
                    ForEach(shelves) { shelf in
                        Button { router.selection = .library(shelf.category) } label: { ShelfCard(shelf: shelf, height: layout.shelfHeight) }
                            .buttonStyle(.plain)
                            .hoverLift(scale: 1.02)
                    }
                }
            }
        }
    }

    // MARK: Recent searches

    @ViewBuilder
    private var recent: some View {
        if !recentSearches.isEmpty {
            HomeSection("Recent searches", action: ("Clear", onForgetAll)) {
                FlowRow(spacing: 8, centered: false) {
                    ForEach(recentSearches) { search in
                        Button { onSearch(search) } label: {
                            Label(search.text, systemImage: search.category.symbolName)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.quaternary, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove", systemImage: "xmark") { onForget(search) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

/// One thing the library got: a title, a book, an album or a game, with its card.
private enum RecentEntry: Identifiable {
    case title(LibraryTitle)
    case book(BookTitle)
    case album(AlbumTitle)
    case game(GameTitle)

    var id: String {
        switch self {
        case .title(let title): "title:\(title.id)"
        case .book(let book): "book:\(book.id)"
        case .album(let album): "album:\(album.id)"
        case .game(let game): "game:\(game.id)"
        }
    }

    var items: [ShelfItem] {
        switch self {
        case .title(let title): title.items
        case .book(let book): book.items
        case .album(let album): album.items
        case .game(let game): game.items
        }
    }

    var added: Date { items.compactMap(\.item.addedAt).max() ?? .distantPast }

    /// What goes behind the field while the pointer rests here: a title's backdrop, else its cover (albums, books and
    /// games have only covers; blurred, they still set the colours, as in Apple Music).
    var backdrop: URL? {
        switch self {
        case .title(let title): title.media?.background ?? title.media?.poster
        case .book(let book): book.book?.cover
        case .album(let album): album.album?.cover
        case .game(let game): game.cover
        }
    }

    /// Width ÷ height of the cover.
    var ratio: CGFloat {
        switch self {
        case .title: 2 / 3
        case .book(let book): book.format.coverRatio
        case .album: 1
        case .game: 3 / 4
        }
    }

    @MainActor @ViewBuilder
    var card: some View {
        switch self {
        case .title(let title): TitleCard(title: title)
        case .book(let book): BookCard(book: book)
        case .game(let game): GameCard(game: game)
        case .album(let album):
            VStack(alignment: .leading, spacing: 4) {
                AlbumCover(title: album.name, artist: album.artist, url: album.album?.cover)
                Text(album.name).scaledFont(.caption, weight: .medium).lineLimit(1)
                Text(album.artist ?? "Album").scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// A horizontal row of posters.
private struct PosterRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) { content }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
        }
        .scrollIndicators(.never)
    }
}

/// A poster with a title and one line under it (episodes waiting, a release date).
private struct PosterTile: View {
    let url: URL?
    let title: String
    let subtitle: String?
    var width: CGFloat = 136

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: url).aspectRatio(2 / 3, contentMode: .fit)
            Text(title).scaledFont(.caption, weight: .medium).lineLimit(1)
            if let subtitle { Text(subtitle).scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(width: width)
        .hoverLift()
        .help(title)
    }
}

/// A section heading with an optional link on the right.
private struct HomeSection<Content: View>: View {
    let title: String
    var action: (String, () -> Void)?
    @ViewBuilder let content: Content

    init(_ title: String, action: (String, () -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).scaledFont(.title2, weight: .bold)
                Spacer()
                if let action {
                    Button(action.0, action: action.1).buttonStyle(.link)
                }
            }
            content
        }
    }
}

/// Something downloading: name, where, a bar.
private struct ProgressCard: View {
    let title: String
    let place: String
    let badge: BackendID?
    let progress: Double?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).scaledFont(.callout, weight: .medium).lineLimit(1).help(title)
            if let progress {
                ProgressView(value: progress)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack(spacing: 6) {
                if let badge { BackendBadge(backend: badge) }
                Text(place)
                Spacer()
                if let detail { Text(detail).monospacedDigit() }
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
        .contentShape(.rect(cornerRadius: 14))
    }
}

/// A kind of the library: symbol, name, count, and a fan of its covers.
private struct ShelfCard: View {
    let shelf: LibraryShelfSummary
    var height: CGFloat = 124

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: shelf.symbol).scaledFont(.title3).foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text(shelf.category.title).scaledFont(.headline)
                Text("\(shelf.count)").scaledFont(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
            covers
        }
        .padding(16)
        .frame(height: height)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(shelf.category.title), \(shelf.count)")
        .accessibilityAddTraits(.isButton)
    }

    private var covers: some View {
        let height = self.height - 32
        let width = height * shelf.coverRatio
        return ZStack(alignment: .trailing) {
            ForEach(Array(shelf.covers.enumerated().reversed()), id: \.element) { index, url in
                CachedImage(url: url) { Rectangle().fill(.quaternary) }
                    .frame(width: width, height: height)
                    .clipShape(.rect(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.3), radius: 3, x: -1)
                    .offset(x: CGFloat(-index) * width * 0.32)
                    .scaleEffect(1 - CGFloat(index) * 0.08, anchor: .trailing)
            }
        }
        .frame(width: width * (1 + 0.32 * CGFloat(max(shelf.covers.count - 1, 0))), alignment: .trailing)
    }
}

/// Items in rows that wrap, left to right (capsules, chips).
private struct FlowRow: Layout {
    var spacing: CGFloat = 8
    /// Rows centred (the service capsules under the field, like Spotlight's suggestions) or from the left.
    var centered = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX + (centered ? (bounds.width - row.width) / 2 : 0)
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
