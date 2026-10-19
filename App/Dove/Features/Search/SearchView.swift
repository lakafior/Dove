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
    /// Rows from the plugins that serve the picked category.
    @State private var pluginSearch = PluginSearch()
    @State private var searchedBooks: String?
    /// The direct-download site's search page, in Dove's browser.
    @State private var directSearch: BrowserRequest?
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
        case .software, .adult, .all: "Name, magnet or link"
        }
    }

    /// Results (or a search on its way, or why there are none) replace the home screen; clearing the field
    /// brings it back.
    private var showsResults: Bool {
        isSearching || releases.isSearching || pluginSearch.isSearching || !pluginSearch.answers.isEmpty
            || !results.isEmpty || !releases.isEmpty || !books.isEmpty
            || ((message != nil || releases.message != nil) && !text.isEmpty)
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
            .sheet(item: $directSearch) { DirectBrowserView(start: $0.url, category: activeCategory) }
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
            if let message = releases.message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if !activeCategory.usesAddons, !releases.isEmpty {
                ReleaseListSection(list: releases, title: books.isEmpty ? nil : "Releases")
            }
            PluginResultsSections(search: pluginSearch)
            directSearchSection
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

    private func clearResults() {
        results = []
        releases.clear()
        pluginSearch.clear()
        books = []
        searchedBooks = nil
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

    /// A file page a plugin knows (`links`) or a direct-download site's `/md5/` page: starts the download and
    /// answers true.
    private func openFilePage(_ url: URL) -> Bool {
        if let link = model.plugins.link(for: url) {
            Task { message = await model.getFile(from: link.call, id: link.id, kind: activeCategory.contentKind) }
            return true
        }
        if model.directSource != nil, let md5 = DirectSource.md5(in: url) {
            Task { message = await model.startDirectDownload(md5: md5) }
            return true
        }
        return false
    }

    private func handleSubmit() {
        message = nil
        // A movie's or series' page (IMDb, Apple TV, Letterboxd…): open that title.
        if SourceDetector.sources(in: text).isEmpty, let link = TitleLink.first(in: text) {
            Task { await model.openTitle(link) }
            return
        }
        // A plugin's or a direct-download site's file page: fetch it.
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
        pluginSearch.search(query, category: category, calls: model.plugins.calls(.search, category: category))
        if let format = category.bookFormat { return searchBooks(query, format: format) }
        if category.newznabCategory != nil { return searchReleases() }
        guard model.addonSet.canSearch else {
            message = "Add a TMDB key or a Stremio addon that can search (for example AIOMetadata or Cinemeta) in Settings."
            return
        }
        isSearching = true
        results = []
        Task {
            do {
                results = try await model.addonSet.search(query)
                if results.isEmpty { message = "Nothing found." }
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
        Section {
            ForEach(books) { book in
                NavigationLink(value: BookSearchRoute(book: book, category: activeCategory)) {
                    BookRow(book: book, format: activeCategory.bookFormat ?? .ebook)
                }
            }
            if let query = searchedBooks, releases.isEmpty, !releases.isSearching {
                Button("Search releases for \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass") { searchReleases() }
            }
        } header: {
            if !books.isEmpty { Text(activeCategory == .audiobooks ? "Audiobooks" : "Books") }
        } footer: {
            if !books.isEmpty { Text("From Open Library and Apple Books. Pick one to search the indexers for it.") }
        }
    }

    /// "Search on <site>" for the direct-download sites that serve the picked category, once a search ran.
    @ViewBuilder
    var directSearchSection: some View {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = model.directSources(for: activeCategory)
        let browsers = model.plugins.browsers(for: activeCategory)
        let searched = !results.isEmpty || !releases.isEmpty || !books.isEmpty || message != nil || releases.message != nil
            || !pluginSearch.answers.isEmpty
        if !query.isEmpty, !sources.isEmpty || !browsers.isEmpty, searched, !isSearching, !releases.isSearching {
            Section {
                ForEach(browsers, id: \.id) { call in
                    if let url = call.browseURL(for: query) {
                        Button("Search on \(call.manifest.name)", systemImage: "safari") { directSearch = BrowserRequest(url: url) }
                    }
                }
                ForEach(sources) { source in
                    Button("Search on \(source.url.host() ?? source.name)", systemImage: "safari") {
                        directSearch = BrowserRequest(url: source.searchURL(query, extensions: []))
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
            // Nothing the services know (Polish editions, obscure titles): straight to the indexers.
            if books.isEmpty { searchReleases() }
        }
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
