import DoveKit
import SwiftUI

/// The smart field: a magnet, info hash, .torrent/.nzb URL or hoster link opens the add sheet;
/// anything else searches in the category picked from the chips under the field: Movies & TV searches titles
/// (TMDB or the metadata addon), every other category searches release names through Dove's own
/// Newznab/Torznab indexers. Sources (toolbar) picks which indexers, and for Movies & TV whether the addons,
/// each category asks.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    /// "Find by description": titles the on-device model suggested and a search confirmed (nil until asked).
    @State private var described: DescribedSearch.Found?
    @State private var isDescribing = false
    @State private var describeError: String?
    @State private var pendingSources: SourceBatch?
    @State private var message: String?
    @State private var results: [MediaSummary] = []
    @State private var isSearching = false
    @State private var typeFilter: MediaType?
    @AppStorage("searchCategory") private var category: SearchCategory = .media
    /// Name searches through Dove's indexers (every category but Movies & TV).
    @State private var releases = ReleaseList()
    /// Books and Audiobooks: the metadata services' answer, before any indexer is asked.
    @State private var books: [BookSummary] = []
    /// Music: MusicBrainz's albums, before any indexer is asked.
    @State private var albums: [AlbumSummary] = []
    @State private var searchedAlbums: String?
    /// Games: IGDB's and Wikidata's games, before any indexer is asked.
    @State private var games: [GameSummary] = []
    @State private var searchedGames: String?
    /// Rows from the plugins that serve the picked category.
    @State private var pluginSearch = PluginSearch()
    @State private var resultsTab = ResultsTab.sources
    @State private var searchedBooks: String?
    /// A plugin's search page, in Dove's browser.
    @State private var siteSearch: BrowserRequest?
    @Environment(\.scenePhase) private var scenePhase
    /// `UIPasteboard.changeCount` the banner was last answered for, so it does not come back for the same copy.
    @AppStorage("clipboardAnsweredChange") private var answeredChange = -1
    @State private var pasteboardChange = -1
    @State private var pasteboardHasContent = false

    private var visibleResults: [MediaSummary] {
        guard let typeFilter else { return results }
        return results.filter { $0.type == typeFilter }
    }

    @State private var home = HomeModel()

    /// Categories other than Movies & TV need an indexer; Adult shows only when adult content does.
    private var categories: [SearchCategory] {
        guard !model.newznab.isEmpty else { return [.media] }
        return SearchCategory.allCases.filter { $0 != .adult || model.showAdult }
    }

    /// The picked category, or Movies & TV when it is no longer offered (indexers removed, adult hidden).
    private var activeCategory: SearchCategory {
        categories.contains(category) ? category : .media
    }

    private var prompt: String {
        switch activeCategory {
        case .media: "Title, magnet or link"
        case .books, .audiobooks: "Author or title, magnet or link"
        case .music: "Artist or album, magnet or link"
        case .games: "Game, magnet or link"
        case .software, .adult, .all: "Name, magnet or link"
        }
    }

    /// Results (or a search on its way, or why there are none) replace the home screen; clearing the field
    /// brings it back.
    private var showsResults: Bool {
        isSearching || releases.isSearching || pluginSearch.isSearching || !pluginSearch.answers.isEmpty
            || !results.isEmpty || !releases.isEmpty || !books.isEmpty || !albums.isEmpty || searchedAlbums != nil
            || !games.isEmpty || searchedGames != nil
            || ((message != nil || releases.message != nil) && !text.isEmpty) || isDescribing || described != nil
    }

    var body: some View {
        NavigationStack(path: Bindable(model).searchPath) {
            Group {
                if showsResults {
                    resultsList
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            categoryBar
                            if pasteboardHasContent, pasteboardChange != answeredChange {
                                clipboardBanner.padding(.horizontal)
                            }
                            if let message {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                            }
                            if categories.count == 1 {
                                Text("Add a Newznab or Torznab indexer in Settings › Search › Indexers to search books, music, software and more.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                            }
                            HomeView(home: home) { search in
                                text = search.text
                                // A category change searches by itself (`onChange(of: category)`).
                                if category == search.category { handleSubmit() } else { category = search.category }
                            }
                            .equatable()
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Dove")
            .searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: prompt
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search, handleSubmit)
            // "Search in Dove" from Siri, Shortcuts or a Quick Action.
            .task(id: model.searchRequest) {
                guard let request = model.searchRequest else { return }
                model.searchRequest = nil
                text = request
                if !request.isEmpty { handleSubmit() }
            }
            .toolbar {
                if !model.newznab.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { SourcesMenu(category: activeCategory, refresh: isSearching) }
                }
            }
            .navigationDestination(for: MediaSummary.self) { MediaDetailView(item: $0) }
            .navigationDestination(for: WatchlistRoute.self) { _ in WatchlistView() }
            .navigationDestination(for: TitleRoute.self) { LibraryTitleView(titleID: $0.id) }
            .navigationDestination(for: BookRoute.self) { BookTitleView(bookID: $0.id) }
            .navigationDestination(for: BookSearchRoute.self) { BookReleasesView(route: $0) }
            .navigationDestination(for: AlbumRoute.self) { AlbumReleasesView(route: $0) }
            .navigationDestination(for: GameRoute.self) { GameReleasesView(route: $0) }
            .navigationDestination(for: ShelfItem.self) { LibraryItemView(item: $0.item) }
            // The field's clear button and Cancel empty the text: back to the home screen.
            .onChange(of: text) {
                if text.isEmpty { clearResults() }
            }
            // Same words, other category: search again rather than leave stale results.
            .onChange(of: activeCategory) {
                clearResults()
                if !text.isEmpty { handleSubmit() }
            }
            // Sources switched for a name search: ask again. Title searches use none of them (the source list does).
            .onChange(of: model.sourceSelection) {
                if !activeCategory.usesAddons, !text.isEmpty, !releases.isEmpty || releases.message != nil { searchReleases() }
            }
            .onAppear(perform: checkPasteboard)
            .onChange(of: scenePhase) { if scenePhase == .active { checkPasteboard() } }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in checkPasteboard() }
            .sheet(item: $siteSearch) { SiteBrowserView(start: $0.url, category: activeCategory) }
            .sheet(item: $pendingSources) { batch in
                AddSourceSheet(sources: batch.sources) { result in
                    pendingSources = nil
                    if result.hasPrefix("Added") { text = "" }
                    message = result.isEmpty ? nil : result
                }
            }
        }
    }

    private var resultsList: some View {
        List {
            if categories.count > 1 {
                categoryBar
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if showsResultTabs {
                ResultsTabPicker(tab: $resultsTab, sourcesTitle: ownResultsTitle, sourcesCount: ownResultsCount, plugins: pluginSearch)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
            }
            if showsResultTabs, resultsTab == .plugins {
                PluginResultsSections(search: pluginSearch, showsState: true)
                siteSearchSection
            } else {
                ownResults
            }
        }
    }

    /// Indexers and plugins both answered something: a tap switches instead of a scroll past every release.
    private var showsResultTabs: Bool {
        pluginSearch.wasAsked && (!releases.isEmpty || releases.isSearching || !books.isEmpty || !albums.isEmpty || !games.isEmpty || !results.isEmpty)
    }

    private var ownResultsTitle: String {
        if !books.isEmpty { return activeCategory == .audiobooks ? "Audiobooks" : "Books" }
        if !albums.isEmpty { return "Albums" }
        if !games.isEmpty { return "Games" }
        if activeCategory == .media, !results.isEmpty { return "Titles" }
        return "Releases"
    }

    private var ownResultsCount: Int? {
        if !books.isEmpty { return books.count }
        if !albums.isEmpty { return albums.count }
        if !games.isEmpty { return games.count }
        if activeCategory == .media, !results.isEmpty { return visibleResults.count }
        return releases.isSearching ? nil : releases.visible.count
    }

    @ViewBuilder
    private var ownResults: some View {
        if isSearching || releases.isSearching {
            HStack { Spacer(); ProgressView(); Spacer() }
                .listRowBackground(Color.clear)
        }
        if let message {
            Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        if !books.isEmpty || searchedBooks != nil {
            booksSection
        }
        if !albums.isEmpty || searchedAlbums != nil {
            albumsSection
        }
        if !games.isEmpty || searchedGames != nil {
            gamesSection
        }
        if let message = releases.message {
            Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }
        if !activeCategory.usesAddons, !releases.isEmpty {
            ReleaseListSection(list: releases, title: books.isEmpty && albums.isEmpty && games.isEmpty ? "Releases from your indexers" : "Releases")
        }
        if !showsResultTabs { PluginResultsSections(search: pluginSearch) }
        siteSearchSection
        if activeCategory == .media {
            describedSection
        }
        if activeCategory == .media, !results.isEmpty {
            Section {
                ForEach(visibleResults) { item in
                    NavigationLink(value: item) { MediaRow(item: item) }
                        .contextMenu { WatchlistMenuItem(media: item) }
                }
            } header: {
                Picker("Type", selection: $typeFilter) {
                    Text("All").tag(MediaType?.none)
                    Text("Movies").tag(MediaType?.some(.movie))
                    Text("Series").tag(MediaType?.some(.series))
                }
                .pickerStyle(.segmented)
                .textCase(nil)
                .padding(.bottom, 4)
            }
        }
    }

    /// At the top of the home screen and of the results, so the category is picked before typing. Part of the
    /// scrolling content, not a `safeAreaInset`: an inset around the home/results swap left the navigation bar
    /// expanded with empty space after a search. Without indexers only Movies & TV exists and the bar is hidden;
    /// the home screen says how to get the rest.
    @ViewBuilder
    private var categoryBar: some View {
        if categories.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.self) { item in
                        let selected = item == activeCategory
                        Button {
                            category = item
                        } label: {
                            Label(item.displayName, systemImage: item.symbolName)
                                .font(.subheadline.weight(selected ? .semibold : .regular))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(selected ? Color.accentColor : .secondary)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    /// A few words that sound like a plot ("the show where office workers…"): Apple Intelligence suggests titles,
    /// a search confirms each, only confirmed ones are listed.
    @ViewBuilder
    private var describedSection: some View {
        let words = text.split(whereSeparator: \.isWhitespace).count
        if let described {
            Section {
                if described.named.isEmpty && described.byPlot.isEmpty {
                    Text("No title found for that description.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(described.named) { item in
                    NavigationLink(value: item) { MediaRow(item: item) }
                        .contextMenu { WatchlistMenuItem(media: item) }
                }
            } header: {
                Label("Fits your description", systemImage: "sparkles")
            } footer: {
                Text("Suggested by Apple Intelligence on this iPhone, and only shown when a search finds the title. Works best for well-known titles.")
            }
            if !described.byPlot.isEmpty {
                Section {
                    ForEach(described.byPlot) { item in
                        NavigationLink(value: item) { MediaRow(item: item) }
                            .contextMenu { WatchlistMenuItem(media: item) }
                    }
                } header: {
                    Text("Might be one of these")
                } footer: {
                    Text("TMDB titles tagged with \(described.plotWords.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")), most popular first.")
                }
            }
        } else if OnDeviceModel.isAvailable, words >= 3, !isSearching, SourceDetector.sources(in: text).isEmpty {
            Section {
                Button(action: describeSearch) {
                    HStack {
                        Label("Find by description", systemImage: "sparkles")
                        Spacer()
                        if isDescribing { ProgressView() }
                    }
                }
                .disabled(isDescribing)
                if let describeError {
                    Text(describeError).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func describeSearch() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isDescribing = true
        describeError = nil
        let addons = model.addonSet
        let key = model.tmdbKey
        Task {
            defer { isDescribing = false }
            do {
                described = try await DescribedSearch.titles(for: query, tmdb: key.isEmpty ? nil : TMDBMetadata(key: key)) {
                    try await addons.search($0)
                }
            } catch {
                describeError = error.localizedDescription
            }
        }
    }

    private func clearResults() {
        resultsTab = .sources
        results = []
        described = nil
        describeError = nil
        releases.clear()
        pluginSearch.clear()
        books = []
        searchedBooks = nil
        albums = []
        searchedAlbums = nil
        games = []
        searchedGames = nil
        message = nil
        typeFilter = nil
    }

    /// Offers what was copied in another app. Only `hasStrings`/`hasURLs` are read here, which iOS does not report
    /// as pasting; the content itself comes through `PasteButton`, i.e. only when the user taps it.
    private var clipboardBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard").foregroundStyle(.secondary)
            Text("Add what you copied?").font(.subheadline)
            Spacer()
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in usePasted(strings.first ?? "") }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            Button {
                answeredChange = pasteboardChange
            } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func checkPasteboard() {
        let pasteboard = UIPasteboard.general
        pasteboardChange = pasteboard.changeCount
        pasteboardHasContent = pasteboard.hasURLs || pasteboard.hasStrings
    }

    /// A magnet or link (also inside longer text) opens the add sheet; anything else becomes a title search.
    private func usePasted(_ pasted: String) {
        answeredChange = pasteboardChange
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true, openFilePage(url) {
            return
        }
        let sources = SourceDetector.sources(in: trimmed)
        if !sources.isEmpty {
            results = []
            pendingSources = SourceBatch(sources)
        } else {
            text = trimmed
            handleSubmit()
        }
    }

    /// A file page a plugin knows (`links`): starts the download and answers true.
    private func openFilePage(_ url: URL) -> Bool {
        if let link = model.plugins.link(for: url) {
            Task { message = await model.getFile(from: link.call, id: link.id, kind: activeCategory.contentKind) }
            return true
        }
        return false
    }

    private func handleSubmit() {
        message = nil
        described = nil
        describeError = nil
        // A movie's or series' page (IMDb, Apple TV, Letterboxd…): open that title.
        if SourceDetector.sources(in: text).isEmpty, let link = TitleLink.first(in: text) {
            Task { await model.openTitle(link) }
            return
        }
        // A file page an installed plugin knows: fetch it through the plugin.
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.hasPrefix("http") == true,
           openFilePage(url) {
            return
        }
        let sources = SourceDetector.sources(in: text)
        if !sources.isEmpty {
            results = []
            pendingSources = SourceBatch(sources)
            return
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let category = activeCategory
        home.remember(query, category: category)
        SiriSuggestions.searched(query)
        if let format = category.bookFormat { return searchBooks(query, format: format) }
        if category == .music { return searchAlbums(query) }
        if category == .games { return searchGames(query) }
        // Categories without a title to pick: the plugins answer the words beside the indexers. Books and
        // Movies & TV ask them once a title is picked (its screen), or here when no title is found.
        if category.newznabCategory != nil {
            searchPlugins()
            return searchReleases()
        }
        guard model.addonSet.canSearch else {
            message = "Add a TMDB key or a Stremio addon that can search (for example AIOMetadata or Cinemeta) in Settings."
            return
        }
        isSearching = true
        results = []
        Task {
            do {
                results = try await model.addonSet.search(query)
                if results.isEmpty {
                    message = "Nothing found."
                    searchPlugins()
                }
            } catch {
                message = error.localizedDescription
            }
            isSearching = false
        }
    }
}

// MARK: - Books and releases

extension SearchView {
    /// Books and Audiobooks start from Open Library and Apple Books (no indexer hits): a tap on a book searches
    /// the indexers for it. "Search releases" keeps the name search for what the services do not know.
    var booksSection: some View {
        let held = model.library.heldBooks
        return Section {
            ForEach(books) { book in
                NavigationLink(value: BookSearchRoute(book: book, category: activeCategory)) {
                    BookRow(book: book, format: activeCategory.bookFormat ?? .ebook,
                            held: held.held(book, format: activeCategory.bookFormat ?? .ebook))
                }
            }
            if let query = searchedBooks, releases.isEmpty, !releases.isSearching, pluginSearch.answers.isEmpty {
                Button("Search releases for \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass") {
                    searchReleases()
                    searchPlugins()
                }
            }
        } header: {
            if !books.isEmpty { Text(activeCategory == .audiobooks ? "Audiobooks" : "Books") }
        } footer: {
            if !books.isEmpty { Text("From Open Library and Apple Books. Pick one to search the indexers for it.") }
        }
    }

    /// "Search on <plugin>" for the plugins with a search page in the picked category, once a search ran.
    @ViewBuilder
    var siteSearchSection: some View {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let browsers = model.plugins.browsers(for: activeCategory)
        let searched = !results.isEmpty || !releases.isEmpty || !books.isEmpty || !albums.isEmpty || !games.isEmpty || message != nil || releases.message != nil
            || !pluginSearch.answers.isEmpty
        if !query.isEmpty, !browsers.isEmpty, searched, !isSearching, !releases.isSearching {
            Section {
                ForEach(browsers, id: \.id) { call in
                    if let url = call.browseURL(for: query) {
                        Button("Search on \(call.manifest.name)", systemImage: "safari") { siteSearch = BrowserRequest(url: url) }
                    }
                }
            }
        }
    }

    func searchBooks(_ query: String, format: BookFormat) {
        isSearching = true
        books = []
        searchedBooks = nil
        releases.clear()
        Task {
            do {
                books = BookSummary.unique(try await model.library.searchBooks(query, format: format))
            } catch {
                message = error.localizedDescription
            }
            searchedBooks = query
            isSearching = false
            // Nothing the services know (Polish editions, obscure titles): straight to the indexers and plugins.
            if books.isEmpty {
                searchReleases()
                searchPlugins()
            }
        }
    }

    /// Music starts from MusicBrainz (no indexer hits): a tap on an album searches the indexers for it.
    var albumsSection: some View {
        Section {
            ForEach(albums) { album in
                NavigationLink(value: AlbumRoute(album: album)) { AlbumRow(album: album) }
            }
            if let query = searchedAlbums, releases.isEmpty, !releases.isSearching, pluginSearch.answers.isEmpty {
                Button("Search releases for \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass") {
                    searchReleases()
                    searchPlugins()
                }
            }
        } header: {
            if !albums.isEmpty { Text("Albums") }
        } footer: {
            if !albums.isEmpty {
                Text("From MusicBrainz\(AppleMusicCatalog.isEnabled ? " and Apple Music" : ""). Pick one to search the indexers for it.")
            }
        }
    }

    func searchAlbums(_ query: String) {
        isSearching = true
        albums = []
        searchedAlbums = nil
        releases.clear()
        Task {
            do {
                albums = try await model.musicMetadata.search(query)
            } catch {
                message = error.localizedDescription
            }
            searchedAlbums = query
            isSearching = false
            // Nothing MusicBrainz knows (or it is busy): straight to the indexers and plugins.
            if albums.isEmpty {
                searchReleases()
                searchPlugins()
            }
        }
    }

    /// Games start from IGDB and Wikidata (no indexer hits): a tap on a game searches the indexers for it.
    var gamesSection: some View {
        Section {
            ForEach(games) { game in
                NavigationLink(value: GameRoute(game: game)) { GameRow(game: game) }
            }
            if let query = searchedGames, releases.isEmpty, !releases.isSearching, pluginSearch.answers.isEmpty {
                Button("Search releases for \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass") {
                    searchReleases()
                    searchPlugins()
                }
            }
        } header: {
            if !games.isEmpty { Text("Games") }
        } footer: {
            if !games.isEmpty {
                Text(model.igdbCredentials == nil
                     ? "From Wikidata. Add IGDB in Settings › Game metadata for covers. Pick one to search the indexers for it."
                     : "From IGDB and Wikidata. Pick one to search the indexers for it.")
            }
        }
    }

    func searchGames(_ query: String) {
        isSearching = true
        games = []
        searchedGames = nil
        releases.clear()
        Task {
            do {
                games = try await model.gameMetadata.search(query)
            } catch {
                message = error.localizedDescription
            }
            searchedGames = query
            isSearching = false
            // Nothing the services know (ROM hacks, obscure titles): straight to the indexers and plugins.
            if games.isEmpty {
                searchReleases()
                searchPlugins()
            }
        }
    }

    /// The field's words through the plugins that search the picked category.
    func searchPlugins() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        pluginSearch.search(query, category: activeCategory, calls: model.plugins.calls(.search, category: activeCategory))
    }

    /// The field's words through the indexers, in the picked category.
    func searchReleases() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let category = activeCategory.newznabCategory else { return }
        releases.search(.text(query, category: category), in: activeCategory, model: model)
    }
}

struct MediaRow: View {
    let item: MediaSummary

    var body: some View {
        HStack(spacing: 12) {
            PosterImage(url: item.poster)
                .frame(width: 46, height: 69)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    Text(item.type == .movie ? "Movie" : "Series")
                    if let year = item.releaseInfo { Text(year) }
                    if let rating = item.imdbRating { Text("★ \(rating)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

struct PosterImage: View {
    let url: URL?

    var body: some View {
        CachedImage(url: url) {
            Rectangle().fill(.quaternary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The app's add sheet: the shared add screen with the app's configured services and priority.
struct AddSourceSheet: View {
    @Environment(AppModel.self) private var model
    let sources: [Source]
    let onFinish: (String) -> Void

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            AddSourceView(
                sources: sources,
                router: model.router,
                onClose: { onFinish($0 ?? "") },
                downloadOnly: $model.downloadOnly,
                startDownloadOnly: { backend, itemID, source in
                    await model.startDownloadOnly(itemID, on: backend, name: source.displayName, pick: .allVideos)
                }
            )
        }
        // Hoster links route by the services' host lists: load them if a day old.
        .task { if sources.contains(where: { $0.kind == .hoster }) { await model.refreshHostLists() } }
        .presentationDetents([.medium, .large])
    }
}
