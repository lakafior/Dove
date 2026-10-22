import DoveKit
import SwiftUI

/// Everything in every debrid, either as titles with posters (matched through the search addon), books and
/// audiobooks with covers (Open Library, Apple Books), or as the raw list of torrents and downloads. Music,
/// software and the rest are listed by name under the shelves. Filters: services, category, status, text.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("libraryMode") private var mode: Mode = .titles
    @State private var filter = LibraryFilter()
    /// A described filter ("series from the 80s in 4K"), on top of `filter`, until cleared.
    @State private var request: LibraryRequest?
    @State private var isDescribing = false
    @State private var describeError: String?
    /// Files view: several items picked for one action.
    @State private var isSelecting = false
    @State private var selection = Set<ShelfItem.ID>()
    /// A batch action waiting for confirmation.
    @State private var pending: BatchRequest?
    /// "Wrong title?" from a poster's menu.
    @State private var fixingTitle: LibraryTitle?
    /// "Wrong book?" from a cover's menu.
    @State private var fixingBook: BookTitle?
    @State private var fixingGame: GameTitle?
    /// Short confirmation (e.g. magnets copied), cleared after a moment.
    @State private var notice: String?

    enum BatchRequest {
        case delete([ShelfItem])
        case reinsert([ShelfItem])
        case move([ShelfItem], to: BackendID)

        var title: String {
            switch self {
            case .delete(let items): items.count == 1 ? "Delete this item?" : "Delete \(items.count) items?"
            case .reinsert(let items): items.count == 1 ? "Add this again?" : "Add \(items.count) items again?"
            case .move(let items, let target): items.count == 1 ? "Move to \(target.displayName)?" : "Move \(items.count) items to \(target.displayName)?"
            }
        }

        var message: String {
            switch self {
            case .delete: "Each item is removed from its debrid or nzbdav, with its files. This cannot be undone."
            case .reinsert: "Dove adds each one to its service again and deletes the old item: for dead, expired or stuck torrents and failed NZB jobs."
            case .move: "Dove adds each one there first; it deletes an original only after that worked. NZBs go to Usenet services only."
            }
        }
    }

    enum Mode: String, CaseIterable {
        case titles, files
        var title: String { self == .titles ? "Titles" : "Files" }
    }

    private var library: LibraryModel { model.library }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .titles: titlesView
                case .files: filesView
                }
            }
            .overlay { emptyState }
            .navigationTitle("Library")
            .searchable(text: $filter.query, prompt: OnDeviceModel.isAvailable ? "Filter, or describe and press Search" : "Filter")
            // Typing filters as it goes; Search on three words or more asks the on-device model what they mean.
            .onSubmit(of: .search) {
                let words = filter.query.split(whereSeparator: \.isWhitespace).count
                if OnDeviceModel.isAvailable, words >= 3 { describe(filter.query) }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .primaryAction) { filterMenu }
                ToolbarItem(placement: .secondaryAction) {
                    NavigationLink(value: WatchlistRoute()) {
                        Label("Watchlist", systemImage: "bookmark")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    // Same as pulling the list down: every service's list, statuses included, one call each.
                    Button(library.isLoading ? "Refreshing…" : "Refresh all statuses", systemImage: "arrow.clockwise") {
                        Task { await library.refresh(using: model) }
                    }
                    .disabled(library.isLoading)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(library.isRematching ? "Re-matching…" : "Re-match all titles", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await library.rematchAll(using: model) }
                    }
                    .disabled(library.isRematching)
                }
                ToolbarItem(placement: .secondaryAction) {
                    @Bindable var model = model
                    Toggle("Show adult content", systemImage: "eye", isOn: $model.showAdult)
                }
                if mode == .files {
                    ToolbarItem(placement: .topBarLeading) { selectButton }
                }
            }
            .confirmationDialog(
                pending?.title ?? "",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { request in
                switch request {
                case .delete(let items):
                    Button("Delete from their services", role: .destructive) { start { await library.delete(items, using: model) } }
                case .reinsert(let items):
                    Button("Reinsert") { start { await library.reinsert(items, using: model) } }
                case .move(let items, let target):
                    Button("Move (delete originals)") {
                        start { await library.move(items, to: target, deleteOriginal: true, using: model) }
                    }
                    Button("Copy (keep originals)") {
                        start { await library.move(items, to: target, deleteOriginal: false, using: model) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(request.message)
            }
            .sheet(item: $fixingTitle) { MatchPickerSheet(title: $0) }
            .sheet(item: $fixingBook) { BookPickerSheet(book: $0) }
            .sheet(item: $fixingGame) { GamePickerSheet(game: $0) }
            .overlay(alignment: .bottom) {
                if let notice {
                    Text(notice)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.opacity)
                        .task {
                            try? await Task.sleep(for: .seconds(2))
                            self.notice = nil
                        }
                }
            }
            .onChange(of: mode) { endSelecting() }
            // A shelf tapped on the home screen: just that kind, other filters cleared.
            .onChange(of: model.libraryCategoryRequest, initial: true) {
                guard let category = model.libraryCategoryRequest else { return }
                filter = LibraryFilter()
                filter.category = category
                mode = .titles
                model.libraryCategoryRequest = nil
            }
            .navigationDestination(for: TitleRoute.self) { LibraryTitleView(titleID: $0.id) }
            .navigationDestination(for: BookRoute.self) { BookTitleView(bookID: $0.id) }
            .navigationDestination(for: ArtistRoute.self) { ArtistView(artistID: $0.id) }
            .navigationDestination(for: LibraryAlbumRoute.self) { LibraryAlbumView(albumID: $0.id) }
            .navigationDestination(for: AlbumRoute.self) { AlbumReleasesView(route: $0) }
            .navigationDestination(for: LibraryGameRoute.self) { LibraryGameView(gameID: $0.id) }
            .navigationDestination(for: GameRoute.self) { GameReleasesView(route: $0) }
            .navigationDestination(for: ShelfItem.self) { LibraryItemView(item: $0.item) }
            .navigationDestination(for: WatchlistRoute.self) { _ in WatchlistView() }
            .navigationDestination(for: MediaSummary.self) { MediaDetailView(item: $0) }
            .refreshable { await library.refresh(using: model) }
            .task { await library.start(using: model) }
        }
    }

    // MARK: - Titles

    /// "All" with nothing typed shows one row per kind (newest first, "See all" opens the kind); a chip, a typed
    /// filter or the Filters menu's Type shows full grids. A library of 1,500 books no longer buries what follows it.
    private var showsShelves: Bool {
        filter.category == nil && filter.query.trimmingCharacters(in: .whitespaces).isEmpty && request == nil
    }

    // MARK: Filtered content

    private var shownTitles: [LibraryTitle] {
        let titles = filter.apply(to: library.titles)
        return request?.apply(to: titles) ?? titles
    }

    private var shownBooks: [BookTitle] {
        let books = filter.apply(to: library.books)
        return request?.apply(to: books) ?? books
    }

    private var shownAlbums: [AlbumTitle] {
        let albums = filter.apply(to: library.albums)
        return request?.apply(to: albums) ?? albums
    }

    private var shownGames: [GameTitle] {
        let games = filter.apply(to: library.games)
        return request?.apply(to: games) ?? games
    }

    private var shownOthers: [ShelfItem] {
        let others = filter.apply(to: library.others)
        return request?.apply(to: others) ?? others
    }

    /// With a described filter, the items of the titles, books and albums it keeps (a series' year is the title's,
    /// not in its release names), so the count and the Files view match what Titles shows.
    private var shownItems: [ShelfItem] {
        guard request != nil else { return filter.apply(to: library.items) }
        let kept = shownTitles.flatMap(\.items) + shownBooks.flatMap(\.items) + shownAlbums.flatMap(\.items)
            + shownGames.flatMap(\.items) + shownOthers
        var seen: Set<ShelfItem.ID> = []
        return kept.filter { seen.insert($0.id).inserted }
    }

    // MARK: Described filter

    private func describe(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isDescribing = true
        describeError = nil
        let services = model.backends.map(\.id)
        Task {
            defer { isDescribing = false }
            do {
                let request = try await DescribedLibrary.request(for: text, services: services)
                withAnimation {
                    self.request = request
                    filter.query = ""
                }
            } catch {
                describeError = error.localizedDescription
            }
        }
    }

    /// What the described filter understood, with a button to clear it; or the model at work, or why it failed.
    @ViewBuilder
    private var describedChip: some View {
        if isDescribing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading your description…")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
        } else if let request {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\u{201C}\(request.text)\u{201D}")
                        Text(request.ignoresGenre
                             ? "\(request.summary) · genres are not known to the Library"
                             : request.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.footnote)
                Spacer()
                Button("Clear", systemImage: "xmark.circle.fill") {
                    withAnimation { self.request = nil }
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
        } else if let describeError {
            Text(describeError).font(.caption).foregroundStyle(.red).padding(.horizontal)
        }
    }

    private var titlesView: some View {
        let titles = shownTitles
        let books = shownBooks
        let artists = LibraryShelf.artists(shownAlbums)
        let games = shownGames
        let others = shownOthers
        return ScrollView {
            categoryChips
            describedChip
            failuresBanner.padding(.horizontal)
            if showsShelves {
                shelf(.movies, titles.filter { $0.type == .movie }, width: 112, cell: titleCell)
                shelf(.series, titles.filter { $0.type == .series }, width: 112, cell: titleCell)
                shelf(.books, books.filter { $0.format == .ebook }, width: 104, cell: bookCell)
                shelf(.audiobooks, books.filter { $0.format == .audiobook }, width: 140, cell: bookCell)
                shelf(.music, artists, width: 120, count: "\(artists.reduce(0) { $0 + $1.albums.count }) albums", cell: artistCell)
                shelf(.games, games, width: 104, cell: gameCell)
                otherFiles(others, limit: 5)
            } else {
                titleGrid("Movies", titles.filter { $0.type == .movie })
                titleGrid("Series", titles.filter { $0.type == .series })
                bookGrid("Books", books.filter { $0.format == .ebook }, minimum: 104)
                bookGrid("Audiobooks", books.filter { $0.format == .audiobook }, minimum: 140)
                artistGrid(artists)
                gameGrid(games)
                otherFiles(others, limit: nil)
            }
        }
    }

    // MARK: Category chips

    /// The kinds the library holds (adult only when shown), as chips; "All" clears the kind. Same state as the
    /// Filters menu's Type.
    private var chipCategories: [LibraryFilter.Category] {
        let items = library.items
        return LibraryFilter.Category.allCases.filter { category in
            (category != .adult || model.showAdult) && items.contains { category.contains($0) }
        }
    }

    @ViewBuilder
    private var categoryChips: some View {
        let categories = chipCategories
        if categories.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    categoryChip("All", nil)
                    ForEach(categories, id: \.self) { categoryChip($0.title, $0) }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func categoryChip(_ title: String, _ category: LibraryFilter.Category?) -> some View {
        let selected = filter.category == category
        return Button(title) {
            withAnimation { filter.category = category }
        }
        .font(.subheadline.weight(selected ? .semibold : .regular))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(selected ? Color.accentColor : .secondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Shelves

    /// One kind as a row of its newest entries; the heading opens the kind.
    @ViewBuilder
    private func shelf<Item: Identifiable, Cell: View>(
        _ category: LibraryFilter.Category,
        _ items: [Item],
        width: CGFloat,
        count: String? = nil,
        @ViewBuilder cell: @escaping (Item) -> Cell
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                seeAllHeading(category.title, count: count ?? "\(items.count)", category: category)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items.prefix(Self.shelfLength)) { cell($0).frame(width: width) }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.bottom)
        }
    }

    private static let shelfLength = 20

    private func seeAllHeading(_ title: String, count: String, category: LibraryFilter.Category) -> some View {
        Button {
            withAnimation { filter.category = category }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                // Plain colours: inside a button `.primary` would take the tint.
                Text(title).font(.title3.bold()).foregroundStyle(Color(uiColor: .label))
                Text(count).font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                Spacer()
                Group {
                    Text("See all").font(.subheadline)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    // MARK: Cells

    private func titleCell(_ title: LibraryTitle) -> some View {
        NavigationLink(value: TitleRoute(id: title.id)) {
            TitleCard(title: title)
        }
        .buttonStyle(.plain)
        .contextMenu {
            kindMenu(title.items)
            if let media = title.media { WatchlistMenuItem(media: media) }
            Button("Wrong title?", systemImage: "magnifyingglass") { fixingTitle = title }
            batchActions(title.items)
            Button("Delete", systemImage: "trash", role: .destructive) { pending = .delete(title.items) }
        }
    }

    private func bookCell(_ book: BookTitle) -> some View {
        NavigationLink(value: BookRoute(id: book.id)) {
            BookCard(book: book)
        }
        .buttonStyle(.plain)
        .contextMenu {
            kindMenu(book.items)
            Button("Wrong book?", systemImage: "magnifyingglass") { fixingBook = book }
            batchActions(book.items)
            Button("Delete", systemImage: "trash", role: .destructive) { pending = .delete(book.items) }
        }
    }

    private func gameCell(_ game: GameTitle) -> some View {
        NavigationLink(value: LibraryGameRoute(id: game.id)) {
            GameCard(game: game)
        }
        .buttonStyle(.plain)
        .contextMenu {
            kindMenu(game.items)
            if !game.isCollection {
                Button("Wrong game?", systemImage: "magnifyingglass") { fixingGame = game }
            }
            batchActions(game.items)
            Button("Delete", systemImage: "trash", role: .destructive) { pending = .delete(game.items) }
        }
    }

    private func artistCell(_ artist: ArtistShelf) -> some View {
        NavigationLink(value: ArtistRoute(id: artist.id)) {
            ArtistCard(artist: artist)
        }
        .buttonStyle(.plain)
        .contextMenu {
            let items = artist.albums.flatMap(\.items)
            kindMenu(items)
            batchActions(items)
            Button("Delete", systemImage: "trash", role: .destructive) { pending = .delete(items) }
        }
    }

    // MARK: Grids

    /// One kind of title under its own heading; nothing when there are none (e.g. filtered to the other kind).
    @ViewBuilder
    private func titleGrid(_ heading: String, _ titles: [LibraryTitle]) -> some View {
        if !titles.isEmpty {
            LazyVStack(alignment: .leading, spacing: 8) {
                gridHeading(heading, count: "\(titles.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                    ForEach(titles) { titleCell($0) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    /// Games and ROM sets under their own heading, box covers.
    @ViewBuilder
    private func gameGrid(_ games: [GameTitle]) -> some View {
        if !games.isEmpty {
            LazyVStack(alignment: .leading, spacing: 8) {
                gridHeading("Games", count: "\(games.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], alignment: .leading, spacing: 16) {
                    ForEach(games) { gameCell($0) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    /// Books and audiobooks under their own heading; audiobook artwork is square, so its tiles are wider.
    @ViewBuilder
    private func bookGrid(_ heading: String, _ books: [BookTitle], minimum: CGFloat) -> some View {
        if !books.isEmpty {
            LazyVStack(alignment: .leading, spacing: 8) {
                gridHeading(heading, count: "\(books.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 12)], alignment: .leading, spacing: 16) {
                    ForEach(books) { bookCell($0) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    /// Music by artist: a tap opens the artist's albums.
    @ViewBuilder
    private func artistGrid(_ artists: [ArtistShelf]) -> some View {
        if !artists.isEmpty {
            LazyVStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Music").font(.title3.bold())
                    let albums = artists.reduce(0) { $0 + $1.albums.count }
                    Text(albums == 1 ? "1 album" : "\(albums) albums").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    // Every album shown (the filters apply), in random order.
                    Button("Shuffle all", systemImage: "shuffle") {
                        Task {
                            if let message = await model.playMusic(artists.flatMap(\.albums), title: "All music", shuffled: true) {
                                notice = message
                            }
                        }
                    }
                    .font(.subheadline)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], alignment: .leading, spacing: 16) {
                    ForEach(artists) { artistCell($0) }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func gridHeading(_ heading: String, count: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(heading).font(.title3.bold())
            Text(count).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Items that are not a title, book or album (software, other files), as rows; on "All" the first few, with
    /// "See all" opening their kind.
    @ViewBuilder
    private func otherFiles(_ others: [ShelfItem], limit: Int?) -> some View {
        if !others.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                if limit != nil {
                    // The kind most of them are, so "See all" lands on a chip that holds them.
                    let kinds = [LibraryFilter.Category.other, .software, .adult]
                    let category = kinds.max { a, b in others.filter(a.contains).count < others.filter(b.contains).count } ?? .other
                    seeAllHeading("Other files", count: "\(others.count)", category: category)
                        .padding(.horizontal, -16)
                        .padding(.bottom, 6)
                } else {
                    gridHeading("Other files", count: "\(others.count)").padding(.bottom, 6)
                }
                ForEach(limit.map { Array(others.prefix($0)) } ?? others) { item in
                    NavigationLink(value: item) {
                        ShelfItemRow(item: item, showsBackend: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        kindMenu([item])
                        batchActions([item])
                        deleteButton(item)
                    }
                    Divider()
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    // MARK: - Files

    private var filesView: some View {
        let items = shownItems
        return List(selection: $selection) {
            categoryChips
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            describedChip
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            failuresBanner
            ForEach(items) { item in
                NavigationLink(value: item) { ShelfItemRow(item: item, showsBackend: true) }
                    .swipeActions { deleteButton(item) }
                    .contextMenu {
                        kindMenu([item])
                        batchActions([item])
                        deleteButton(item)
                    }
            }
        }
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar(visible: items) }
        }
    }

    private var selectButton: some View {
        Button(isSelecting ? "Done" : "Select") {
            if isSelecting { endSelecting() } else { isSelecting = true }
        }
        .disabled(library.batch != nil)
    }

    /// Select all of what the filters show (e.g. one service), then change, fix, move or delete the picked ones.
    private func selectionBar(visible items: [ShelfItem]) -> some View {
        HStack {
            Button(selection.count == items.count && !items.isEmpty ? "Select none" : "Select all") {
                selection = selection.count == items.count ? [] : Set(items.map(\.id))
            }
            Spacer()
            let picked = library.items.filter { selection.contains($0.id) }
            if let batch = library.batch {
                ProgressView()
                Text("\(batch.label) \(batch.done) of \(batch.total)…").font(.footnote)
            } else {
                Group {
                    kindMenu(picked)
                    Menu("Actions", systemImage: "ellipsis.circle") { batchActions(picked) }
                    Button("Delete \(selection.count)", systemImage: "trash", role: .destructive) { pending = .delete(picked) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
                .disabled(selection.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// Starts a confirmed batch action; the selection ends once it is done.
    private func start(_ action: @escaping () async -> Void) {
        Task {
            await action()
            endSelecting()
        }
    }

    /// Copy magnets, Reinsert and Move for what among `items` can be added again (torrents by hash, NZBs that
    /// nzbdav hands back), and a status refresh.
    @ViewBuilder
    private func batchActions(_ items: [ShelfItem]) -> some View {
        let readdable = items.filter { model.canReAdd($0.item) }
        let torrents = readdable.filter { $0.item.magnet != nil }
        let skipped = items.count - readdable.count
        if readdable.isEmpty {
            Button(model.reAddBlocker(items.map(\.item)), systemImage: "info.circle") {}
                .disabled(true)
        } else {
            Section {
                if !torrents.isEmpty {
                    Button(torrents.count == 1 ? "Copy magnet" : "Copy \(torrents.count) magnets", systemImage: "link") {
                        UIPasteboard.general.string = torrents.compactMap(\.item.magnet).joined(separator: "\n")
                        withAnimation { notice = torrents.count == 1 ? "Magnet copied." : "\(torrents.count) magnets copied." }
                    }
                }
                Button("Reinsert", systemImage: "arrow.clockwise.circle") { pending = .reinsert(readdable) }
                // Every service at least one of these can go to, in order.
                let targets = readdable.flatMap { model.moveTargets(for: $0.item) }.reduce(into: [BackendID]()) {
                    if !$0.contains($1) { $0.append($1) }
                }
                if !targets.isEmpty {
                    Menu("Move to", systemImage: "arrow.right.circle") {
                        ForEach(targets, id: \.self) { target in
                            Button(target.displayName) {
                                pending = .move(readdable.filter { model.moveTargets(for: $0.item).contains(target) }, to: target)
                            }
                        }
                    }
                }
            } header: {
                if skipped > 0 {
                    Text("\(readdable.count) can be added again · \(skipped) skipped (no magnet or stored NZB)")
                }
            }
        }
        Button("Refresh status", systemImage: "arrow.triangle.2.circlepath") {
            Task { await library.refresh(using: model) }
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    // MARK: - Pieces

    /// "Updating…" while the services are asked (the cached list stays on screen), when the list is from, how
    /// much it holds, and what failed.
    @ViewBuilder
    private var failuresBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if library.isLoading, !library.items.isEmpty {
                    ProgressView().controlSize(.mini)
                    Text(["Updating…", usage].compactMap { $0 }.joined(separator: " · "))
                } else if let updatedAt = library.updatedAt {
                    Text(["Updated \(updatedAt.formatted(.relative(presentation: .named)))", usage].compactMap { $0 }.joined(separator: " · "))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !library.failures.isEmpty {
                Label(library.failures.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "46 items, 1.1 TB", over what the filters leave.
    private var usage: String? {
        let usage = LibraryUsage(shownItems)
        guard usage.items > 0 else { return nil }
        let count = usage.items == 1 ? "1 item" : "\(usage.items) items"
        return usage.bytes > 0 ? "\(count), \(usage.bytes.formatted(.byteCount(style: .file)))" : count
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.backends.isEmpty {
            ContentUnavailableView("Nothing configured", systemImage: "key", description: Text("Add an API key in Settings."))
        } else if library.isLoading && library.items.isEmpty {
            ProgressView()
        } else if library.hasLoaded && library.items.isEmpty {
            ContentUnavailableView("Your library is empty", systemImage: "tray")
        } else if library.hasLoaded && !isDescribing && shownItems.isEmpty {
            ContentUnavailableView.search(text: filter.query)
        }
    }

    private var filterMenu: some View {
        Menu("Filters", systemImage: filter.isActive
             ? "line.3.horizontal.decrease.circle.fill"
             : "line.3.horizontal.decrease.circle") {
            Section("Services") {
                ForEach(model.backends.map(\.id), id: \.self) { backend in
                    Toggle(backend.displayName, isOn: Binding(
                        get: { filter.backends.contains(backend) },
                        set: { on in
                            if on { filter.backends.insert(backend) } else { filter.backends.remove(backend) }
                        }
                    ))
                }
            }
            Picker("Type", selection: $filter.category) {
                Text("Everything").tag(LibraryFilter.Category?.none)
                ForEach(LibraryFilter.Category.allCases.filter { $0 != .adult || model.showAdult }, id: \.self) {
                    Text($0.title).tag(LibraryFilter.Category?.some($0))
                }
            }
            Picker("Status", selection: $filter.status) {
                Text("Any status").tag(LibraryFilter.Status?.none)
                ForEach(LibraryFilter.Status.allCases, id: \.self) { Text($0.title).tag(LibraryFilter.Status?.some($0)) }
            }
            if filter.isActive {
                Button("Clear filters", role: .destructive) {
                    let query = filter.query
                    filter = LibraryFilter()
                    filter.query = query
                }
            }
        }
    }

    /// "Change type": the kind for these items (a whole title, one row, or the selection). A checkmark marks
    /// the kind the user already set; "Automatic" goes back to what the files and the name say.
    private func kindMenu(_ items: [ShelfItem]) -> some View {
        let manual = Set(items.map { library.manualKind(of: $0) })
        let current = manual.count == 1 ? manual.first! : nil
        return Menu("Change type", systemImage: "tag") {
            Button {
                Task { await library.setKind(nil, for: items, using: model) }
            } label: {
                if manual == [nil] { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            Divider()
            ForEach(ContentKind.allCases, id: \.self) { kind in
                Button {
                    Task { await library.setKind(kind, for: items, using: model) }
                } label: {
                    Label(kind.displayName, systemImage: current == kind ? "checkmark" : kind.symbol)
                }
            }
        }
    }

    private func deleteButton(_ item: ShelfItem) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            Task { await library.delete(item, using: model) }
        }
    }
}

struct TitleRoute: Hashable {
    let id: String
}

/// Poster tile: artwork (or the title on a plain card), name, year, services, and a status mark.
private struct TitleCard: View {
    let title: LibraryTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                CachedImage(url: title.media?.poster) {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text(title.name)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(6)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                LibraryStatusMark(status: title.status, count: title.items.count).padding(5)
            }
            .overlay(alignment: .topLeading) {
                if let coverage = title.coverage {
                    Text(coverage)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(5)
                }
            }
            Text(title.name).font(.caption.weight(.medium)).lineLimit(1)
            HStack(spacing: 3) {
                if let year = title.year { Text(year).font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 2)
                ForEach(title.backends, id: \.self) { BackendBadge(backend: $0) }
            }
        }
    }
}

/// Upload ratio of a seeding torrent: red below 0.5, orange below 1, green from 1 (most private trackers ask for 1).
struct SeedingRatio: View {
    let ratio: Double
    var isActive = true

    var body: some View {
        Label(ratio.formatted(.number.precision(.fractionLength(2))), systemImage: isActive ? "arrow.up.circle.fill" : "arrow.up.circle")
            .labelStyle(.titleAndIcon)
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityLabel("Seeding ratio \(ratio.formatted(.number.precision(.fractionLength(2))))")
    }

    private var color: Color {
        if ratio >= 1 { return .green }
        if ratio >= 0.5 { return .orange }
        return .red
    }
}

/// Top corner of a poster or cover: how many releases when ready, otherwise downloading or failed.
struct LibraryStatusMark: View {
    let status: LibraryFilter.Status
    let count: Int

    var body: some View {
        switch status {
        case .ready:
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        case .active:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white, .blue)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red)
        }
    }
}

/// One torrent or download: name, service, what it holds (episode, season, music…), status, size.
struct ShelfItemRow: View {
    let item: ShelfItem
    var showsBackend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name).font(.subheadline).lineLimit(2)
            if item.isRenamed {
                // The service's own (random) name, so the item can still be found there.
                Text(item.item.name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            HStack(spacing: 8) {
                if showsBackend { BackendBadge(backend: item.item.backend) }
                if item.kind != .video {
                    Label(item.kind.displayName, systemImage: item.kind.symbol)
                } else if let scope = item.guess.scope {
                    Text(scope.label).fontWeight(.medium)
                }
                Text(item.item.status.label)
                if let size = item.item.size {
                    Text(size.formatted(.byteCount(style: .file)))
                }
                if let seeding = item.item.seeding {
                    SeedingRatio(ratio: seeding.ratio, isActive: seeding.isActive)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Files of one item, each playable in the user's player or copyable as a link.
struct LibraryItemView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem
    @State private var detail: LibraryItem?
    @State private var message: String?
    @State private var isChoosingFiles = false
    @State private var confirmReinsert = false
    @State private var pendingMove: BackendID?
    @State private var isWorking = false

    private var current: LibraryItem { detail ?? item }

    /// Services that take this item's kind of source (debrids for torrents, Usenet for NZBs).
    private var moveTargets: [BackendID] {
        model.moveTargets(for: current)
    }

    /// In name order, so episodes read E01, E02… (services list them in their own order).
    private var files: [LibraryFile] {
        (detail ?? item).files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Seasons when the files are episodes, else folders: multi-season packs are unreadable as one list.
    private var fileGroups: [FileGroup] {
        FileGroups.groups(current.files, release: ReleaseParser.guess(displayName))
    }

    /// The library's readable name when the service lists a random one (`AddedHint`, file names).
    private var displayName: String {
        model.library.items.first { $0.item.backend == item.backend && $0.item.id == item.id }?.name
            ?? LibraryNaming.readableName(of: current, hint: nil)
    }

    /// Sections the user opened or closed; with three or more, all start closed.
    @State private var toggledGroups: Set<FileGroup.ID> = []
    /// Links being fetched for a season's playlist.
    @State private var preparing: (done: Int, total: Int)?

    private func isExpanded(_ group: FileGroup) -> Bool {
        (fileGroups.count <= 2) != toggledGroups.contains(group.id)
    }

    private func groupHeader(_ group: FileGroup) -> some View {
        HStack(spacing: 14) {
            Button {
                if !toggledGroups.insert(group.id).inserted { toggledGroups.remove(group.id) }
            } label: {
                HStack {
                    Text(group.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text("\(group.files.count) file\(group.files.count == 1 ? "" : "s")"
                         + (group.size > 0 ? " · " + group.size.formatted(.byteCount(style: .file)) : ""))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded(group) ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .accessibilityHint(isExpanded(group) ? "Hides the files" : "Shows the files")
            if case .season = group.kind, !videos(in: group).isEmpty {
                Button { playAll(in: group) } label: { Image(systemName: "play.circle.fill").font(.title3) }
                    .foregroundStyle(.tint)
                    .disabled(preparing != nil)
                    .accessibilityLabel("Play \(group.title)")
            }
        }
        .buttonStyle(.plain)
        .font(.caption)
        .textCase(nil)
        .foregroundStyle(.secondary)
    }

    private func videos(in group: FileGroup) -> [LibraryFile] {
        group.files.filter { FileKind.isVideo($0.name) && !FileKind.isSample($0.name) }
    }

    /// The season's videos as one playlist, named by their own file names (scene names read well). Players
    /// without playlists get the first video.
    private func playAll(in group: FileGroup) {
        let all = videos(in: group)
        let files = model.playback.limit(all)
        guard preparing == nil, !files.isEmpty, let backend = model.backend(item.backend) else { return }
        let itemID = item.id
        let jobs = files.map { file in
            { @Sendable in try await backend.playbackURL(itemID: itemID, fileID: file.id) }
        }
        message = nil
        preparing = (0, files.count)
        Task {
            defer { preparing = nil }
            let (urls, failure) = await LinkBatch.fetch(jobs) { preparing = ($0, files.count) }
            let playable = zip(files, urls).compactMap { file, url in
                url.map { PlayEntry(url: $0, filename: (file.name as NSString).lastPathComponent) }
            }
            guard !playable.isEmpty else {
                message = failure ?? "Nothing to play."
                return
            }
            do {
                try await model.playback.play(playable)
            } catch {
                message = error.localizedDescription
                return
            }
            if let failure, playable.count < files.count {
                message = "Skipped \(files.count - playable.count) of \(files.count): \(failure)"
            } else {
                message = model.playback.singleFileNote(requested: all.count)
            }
        }
    }

    private func fileRow(_ file: LibraryFile, name: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.subheadline)
            HStack(spacing: 10) {
                if let size = file.size {
                    Text(size.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Places' links are the user's own server or device (Calibre's need its login): no link to share.
                if !item.backend.isStorage {
                    Button { copyLink(file) } label: { Image(systemName: "link") }
                        .accessibilityLabel("Copy link")
                }
                // Files already in iCloud Drive › Dove are on this device: nothing to fetch.
                if !item.backend.isOnDevice {
                    downloadButton(file)
                }
                // Players take video; other files are for the link or the phone.
                if FileKind.isVideo(file.name) {
                    Button { play(file) } label: { Image(systemName: "play.fill") }
                        .accessibilityLabel(model.playback.playLabel)
                }
            }
            // Bordered buttons keep their own tap areas inside a list row.
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .contextMenu {
            if FileKind.isVideo(file.name) {
                Button(model.playback.playLabel, systemImage: "play") { play(file) }
                PlayInMenu { play(file, in: $0) }
            }
            if let album = musicRelease, AudiobookTracks.playableExtensions.contains((file.name as NSString).pathExtension.lowercased()) {
                Button("Play from here", systemImage: "play") {
                    Task { message = await model.playMusic([album], title: album.name, cover: album.album?.cover, start: .file(file.id)) }
                }
            }
            if !item.backend.isStorage {
                Button("Copy link", systemImage: "link") { copyLink(file) }
            }
            if !item.backend.isOnDevice {
                Button("Download to phone", systemImage: "arrow.down.circle") { download(file) }
                if model.iCloudFolder != nil {
                    Button("Save to iCloud Drive", systemImage: "icloud.and.arrow.down") { download(file, to: .iCloud) }
                }
            }
        }
    }

    /// A music item: its album in the Library, with only this release, for Play and Shuffle here.
    private var musicRelease: AlbumTitle? {
        let id = ShelfItem.id(backend: item.backend, itemID: item.id)
        guard var album = model.library.albums.first(where: { $0.items.contains { $0.id == id } }) else { return nil }
        album.items = album.items.filter { $0.id == id }
        return album
    }

    /// Set when the service waits for the user to pick files (Real-Debrid).
    private var fileSelector: (any FileSelecting)? {
        guard (detail ?? item).status == .awaitingFileSelection else { return nil }
        return model.backend(item.backend) as? any FileSelecting
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Service") { BackendBadge(backend: item.backend) }
                LabeledContent("Status", value: (detail ?? item).status.label)
                if let size = item.size {
                    LabeledContent("Size", value: size.formatted(.byteCount(style: .file)))
                }
            }
            if let album = musicRelease, current.status == .ready {
                Section {
                    MusicPlayButtons(albums: [album], title: album.name, cover: album.album?.cover)
                } footer: {
                    Text("Plays this release in Dove. Touch and hold a track to start there.")
                }
            }
            if let seeding = current.seeding {
                Section {
                    LabeledContent("Ratio") { SeedingRatio(ratio: seeding.ratio) }
                    LabeledContent("Seeding", value: seeding.isActive ? "Yes" : "Stopped")
                    if seeding.isActive, let speed = seeding.uploadSpeed {
                        LabeledContent("Upload", value: speed.formatted(.byteCount(style: .file)) + "/s")
                    }
                    if seeding.isActive, let peers = seeding.peers {
                        LabeledContent("Peers", value: "\(peers)")
                    }
                } header: {
                    Text("Seeding")
                } footer: {
                    Text("\(item.backend.displayName) keeps seeding after the download, which private trackers count toward your ratio. Pull down to update.")
                }
            }
            if let message {
                Text(message).font(.footnote)
            }
            if current.failedOnCompressedArchive {
                compressedArchiveSection
            }
            if fileSelector != nil {
                Section {
                    Button("Choose files", systemImage: "checklist") { isChoosingFiles = true }
                } footer: {
                    Text("\(item.backend.displayName) waits for you to choose which files to download.")
                }
            }
            ForEach(fileGroups) { group in
                Section {
                    if isExpanded(group) {
                        ForEach(group.files) { file in fileRow(file, name: group.displayName(of: file)) }
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .overlay {
            if detail == nil && files.isEmpty && message == nil { ProgressView() }
        }
        .overlay(alignment: .bottom) { PreparingBadge(progress: preparing) }
        .sheet(isPresented: $isChoosingFiles) {
            // Not `fileSelector`: the status changes on success, before the sheet is dismissed.
            if let backend = model.backend(item.backend) as? any FileSelecting {
                FileSelectionView(backend: backend, itemID: item.id) {
                    await loadDetail()
                    await model.library.refresh(using: model, afterChange: true)
                }
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { actionsMenu }
        }
        .confirmationDialog("Add this again?", isPresented: $confirmReinsert, titleVisibility: .visible) {
            Button("Reinsert on \(item.backend.displayName)") { reinsert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(current.magnet != nil
                 ? "Dove adds the same torrent to \(item.backend.displayName) again and deletes this item. Use it for dead, expired or stuck torrents."
                 : "Dove asks nzbdav to queue this job's NZB again (a retry) and removes this entry.")
        }
        .confirmationDialog(
            "Move to \(pendingMove?.displayName ?? "")?",
            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
            titleVisibility: .visible,
            presenting: pendingMove
        ) { target in
            Button("Move (delete from \(item.backend.displayName))") { move(to: target, deleteOriginal: true) }
            Button("Copy (keep it here too)") { move(to: target, deleteOriginal: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Dove adds it there first; it deletes this item only after that worked.")
        }
        .disabled(isWorking)
        .refreshable { await loadDetail() }
        .task { await loadDetail() }
    }

    /// A job nzbdav failed on a compressed archive: one tap moves the same NZB to the next Usenet service,
    /// which downloads and unpacks it.
    @ViewBuilder private var compressedArchiveSection: some View {
        let target = model.compressedArchiveTarget(after: item.backend)
        Section {
            if let target, model.moveTargets(for: current).contains(target) {
                Button("Send to \(target.displayName)", systemImage: "arrow.right.circle") {
                    move(to: target, deleteOriginal: true)
                }
            }
        } footer: {
            let explanation = CompressedArchive.explanation(on: item.backend)
            if let target {
                Text(model.canReAdd(current)
                     ? "\(explanation) \(target.displayName) downloads and unpacks it; Dove removes this job after the add worked."
                     : "\(explanation) \(item.backend.displayName) did not keep this job's NZB, so add the release again from Search and pick \(target.displayName).")
            } else {
                Text("\(explanation) A service that unpacks archives can: turn on Usenet for TorBox, Premiumize or Offcloud in Settings.")
            }
        }
    }

    /// DMM-style actions for torrents (by info hash) and NZBs nzbdav hands back, and a status refresh for everything.
    private var actionsMenu: some View {
        Menu("Actions", systemImage: "ellipsis.circle") {
            if let magnet = current.magnet, let hash = current.infoHash {
                Section {
                    Button("Copy magnet", systemImage: "link") { copy(magnet, "Magnet copied.") }
                    Button("Copy hash", systemImage: "number") { copy(hash, "Hash copied.") }
                }
            }
            if model.canReAdd(current) {
                Section {
                    Button("Reinsert", systemImage: "arrow.clockwise.circle") { confirmReinsert = true }
                    if !moveTargets.isEmpty {
                        Menu("Move to", systemImage: "arrow.right.circle") {
                            ForEach(moveTargets, id: \.self) { target in
                                Button(target.displayName) { pendingMove = target }
                            }
                        }
                    }
                }
            } else {
                Button(model.reAddBlocker([current]), systemImage: "info.circle") {}
                    .disabled(true)
            }
            Button("Refresh status", systemImage: "arrow.triangle.2.circlepath") {
                Task {
                    message = nil
                    await loadDetail()
                    if message == nil { message = "Status: \(current.status.label)." }
                }
            }
        }
    }

    private func copy(_ text: String, _ confirmation: String) {
        UIPasteboard.general.string = text
        message = confirmation
    }

    private func reinsert() {
        guard let backend = model.backend(item.backend) else { return }
        run("Reinserting…") {
            _ = try await LibraryActions.reinsert(current, on: backend)
            return true
        }
    }

    private func move(to target: BackendID, deleteOriginal: Bool) {
        guard let source = model.backend(item.backend), let destination = model.backend(target) else { return }
        run("Adding to \(target.displayName)…") {
            _ = try await LibraryActions.move(current, from: source, to: destination, deleteOriginal: deleteOriginal)
            if !deleteOriginal { message = "Added to \(target.displayName)." }
            return deleteOriginal
        }
    }

    /// Runs an action, refreshes the library, and leaves the screen when the item is gone.
    private func run(_ progress: String, _ action: @escaping () async throws -> Bool) {
        isWorking = true
        message = progress
        Task {
            defer { isWorking = false }
            do {
                let removed = try await action()
                await model.library.refresh(using: model, afterChange: true)
                if removed { dismiss() } else if message == progress { message = nil }
            } catch {
                message = error.localizedDescription
                await model.library.refresh(using: model, afterChange: true)
            }
        }
    }

    /// Some backends (Real-Debrid, Offcloud) only return files from a per-item call.
    private func loadDetail() async {
        guard let backend = model.backend(item.backend) else { return }
        do {
            let loaded = try await backend.item(item.id)
            detail = loaded
            model.library.learnKind(from: loaded)
        } catch {
            message = error.localizedDescription
        }
    }

    private func link(for file: LibraryFile) async -> URL? {
        guard let backend = model.backend(item.backend) else { return nil }
        do {
            // nzbdav's link carries the WebDAV login; players and copied links cannot send headers.
            return try await backend.playbackURL(itemID: item.id, fileID: file.id)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    private func play(_ file: LibraryFile, in player: ExternalPlayer? = nil) {
        Task {
            // The file name lets Infuse recognise the episode or movie whatever the link's path says.
            let name = (file.name as NSString).lastPathComponent
            guard let url = await link(for: file) else { return }
            do {
                try await model.playback.play([PlayEntry(url: url, filename: name)], in: player)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Shows where the file stands on this device: download, progress, or done.
    @ViewBuilder
    private func downloadButton(_ file: LibraryFile) -> some View {
        let record = model.downloads.records.first {
            $0.isSameFile(backend: item.backend, itemID: item.id, fileID: file.id)
        }
        switch record?.state {
        case .downloading:
            Button {} label: {
                ProgressRing(progress: record?.progress ?? 0)
            }
            .disabled(true)
            .accessibilityLabel("Downloading")
        case .finished:
            Button {} label: { Image(systemName: "checkmark") }
                .disabled(true)
                .accessibilityLabel("Downloaded")
        default:
            Button { download(file) } label: { Image(systemName: "arrow.down") }
                .accessibilityLabel("Download to phone")
        }
    }

    private func download(_ file: LibraryFile, to destination: DownloadDestination = .device) {
        Task {
            do {
                try await model.download(file, of: detail ?? item, to: destination)
                message = "Downloading \(file.name) to \(destination.displayName). Progress is in the Downloads tab."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func copyLink(_ file: LibraryFile) {
        Task {
            if let url = await link(for: file) {
                UIPasteboard.general.url = url
                message = "Link copied."
            }
        }
    }
}

extension LibraryItem.Status {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .awaitingFileSelection: "Choose files"
        case .downloading(let progress): "Downloading \(Int(progress * 100))%"
        case .ready: "Ready"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

/// Small determinate ring; sized like an SF Symbol in a small button.
private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}
