import DoveAppCore
import DoveKit
import SwiftUI

/// The Search page, and the first page Dove opens on: a large Spotlight-style field, and under it either the results
/// or the home sections (services, what is in progress, recently added, the library's shelves, recent searches).
/// Movies & TV: TMDB or the metadata addons answer with posters, a click opens the title with its sources; a title
/// link (IMDb, Apple TV, Letterboxd…) opens that title. Books, audiobooks, music and games: their metadata services answer
/// with covers, a click opens the releases page (`MacReleasesView`). Software, Adult and All: the indexers by name, as
/// a table here; so do the other categories when their services find nothing.
struct MacSearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    @AppStorage("macSearchCategory") private var category: SearchCategory = .media
    @State private var home = HomeModel()
    @State private var suggestions = SearchSuggestions()
    @FocusState private var isFieldFocused: Bool
    /// The words of the search on screen; empty shows the home sections.
    @State private var searched = ""
    @State private var results: [MediaSummary] = []
    @State private var isSearching = false
    @State private var message: String?
    /// All results, or only movies or only series (as on the iPhone).
    @State private var typeFilter: MediaType?
    @State private var layout = HomeLayout()
    /// The backdrop of the poster the pointer rests on (it stays after the pointer leaves, like Apple TV).
    @State private var hoveredBackdrop: URL?
    @State private var hoverTask: Task<Void, Never>?
    /// Books, albums or games from the category's metadata services.
    @State private var covers: [CoverResult] = []
    /// The indexers by name (and the plugins), shown in place of covers.
    @State private var releases = ReleaseList()
    @State private var pluginSearch = PluginSearch()
    @State private var siteSearch: BrowserRequest?
    @State private var isNameSearch = false

    /// Adult only when shown.
    private var categories: [SearchCategory] {
        SearchCategory.allCases.filter { $0 != .adult || model.showAdult }
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.searchPath) {
            ScrollView {
                VStack(spacing: 36) {
                    SpotlightField(
                        text: $router.searchText, category: $category, categories: categories, focus: $isFieldFocused,
                        suggestions: isFieldFocused ? suggestions.items : [], onPick: router.open
                    ) { search(router.searchText) }
                        .frame(maxWidth: layout.fieldWidth)
                        .padding(.top, 48)
                    if searched.isEmpty {
                        MacHomeSections(
                            layout: layout, recentSearches: home.recentSearches,
                            onSearch: repeatSearch, onForget: home.forget, onForgetAll: home.forgetAll,
                            onHoverBackdrop: hover
                        )
                    } else {
                        searchResults
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { layout.width = $0 }
            // Captions and headings grow with the posters on a large window.
            .environment(\.textScale, layout.scale)
            .background(alignment: .top) { HeroBackdrop(url: hoveredBackdrop ?? backdrop) }
            .navigationTitle("")
            .navigationDestination(for: MediaSummary.self) { MacTitleView(media: $0) }
            .navigationDestination(for: ReleaseTarget.self) { MacReleasesView(target: $0) }
            .toolbar {
                if !searched.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        Button("Home", systemImage: "chevron.backward") { clear() }
                            .help("Back to the start page")
                    }
                }
            }
        }
        // Suggestions follow the typing, not a search that just ran (which puts its words in the field).
        .onChange(of: router.searchText) {
            if router.searchText != searched { suggestions.update(router.searchText, category: category, model: model) }
        }
        .onChange(of: category) {
            results = []
            message = nil
            if !searched.isEmpty { search(searched) }
        }
        // A link, Spotlight, or the ⌘F panel on another page.
        .task(id: router.searchRequest) {
            guard let request = router.searchRequest else { return }
            router.searchRequest = nil
            search(request)
        }
        // ⌘F on this page: the field here takes the words.
        .onChange(of: router.focusSearchRequest) { isFieldFocused = true }
        .onAppear { if searched.isEmpty { isFieldFocused = true } }
        .onExitCommand { clear() }
        .sheet(item: $siteSearch) { request in
            SiteBrowserView(start: request.url, category: category)
                .frame(minWidth: 900, idealWidth: 1100, minHeight: 620, idealHeight: 760)
        }
    }

    /// The newest library title with a backdrop: the start page's background.
    private var backdrop: URL? {
        model.library.titles
            .filter { $0.media?.background != nil }
            .max { ($0.latestAdded ?? .distantPast) < ($1.latestAdded ?? .distantPast) }?
            .media?.background
    }

    /// Waits for the pointer to stop: sweeping across a row does not fade through every cover on the way.
    private func hover(_ url: URL?) {
        hoverTask?.cancel()
        guard let url, url != hoveredBackdrop else { return }
        hoverTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            hoveredBackdrop = url
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var searchResults: some View {
        if isNameSearch {
            nameSearch
        } else if category != .media {
            coverResults
        } else if isSearching {
            ProgressView("Searching…").padding(.top, 40)
        } else if !results.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                // A filter of what is shown, so it sits with the results.
                Picker("Show", selection: $typeFilter) {
                    Text("All").tag(MediaType?.none)
                    Text("Movies").tag(MediaType?.some(.movie))
                    Text("Series").tag(MediaType?.some(.series))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.resultWidth), spacing: 16)], alignment: .leading, spacing: 20) {
                    ForEach(results.filter { typeFilter == nil || $0.type == typeFilter }) { media in
                        Button { router.pushSearch(media) } label: { ResultCard(media: media) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: layout.contentWidth, alignment: .leading)
        } else if let message {
            ContentUnavailableView("Cannot search", systemImage: "exclamationmark.magnifyingglass", description: Text(message))
        } else {
            ContentUnavailableView.search(text: searched)
        }
    }

    // MARK: - Actions

    private func repeatSearch(_ recent: HomeModel.RecentSearch) {
        category = recent.category
        router.searchText = recent.text
        search(recent.text)
    }

    /// Back to the start page.
    private func clear() {
        searched = ""
        results = []
        message = nil
        router.searchText = ""
        isFieldFocused = true
    }

    /// Books, albums or games as covers; a click opens their releases.
    @ViewBuilder
    private var coverResults: some View {
        if isSearching {
            ProgressView("Searching…").padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: layout.resultWidth), spacing: 16)], alignment: .leading, spacing: 20) {
                    ForEach(covers) { cover in
                        Button { router.pushSearch(cover.target) } label: { CoverResultCard(cover: cover) }
                            .buttonStyle(.plain)
                    }
                }
                Button("Search releases for \u{201C}\(searched)\u{201D}", systemImage: "magnifyingglass") { searchByName(searched) }
                    .buttonStyle(.link)
                    .help("Your indexers and plugins by the words, for what the metadata services do not know")
            }
            .frame(maxWidth: layout.contentWidth, alignment: .leading)
        }
    }

    /// The indexers' rows as a table (and the plugins' answers under it), for categories without metadata or when
    /// nothing was found.
    private var nameSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacReleasesTable(list: releases)
                .frame(height: 560 * layout.scale)
                .clipShape(.rect(cornerRadius: 12))
            siteSearchButtons
            if !pluginSearch.isEmpty || pluginSearch.isSearching {
                Text("From plugins").scaledFont(.title2, weight: .bold)
                MacPluginResults(search: pluginSearch)
                    .frame(height: 320 * layout.scale)
                    .clipShape(.rect(cornerRadius: 12))
            }
        }
        .frame(maxWidth: layout.contentWidth)
    }

    /// "Search on <plugin>" for the plugins with a search page in this category, once a name search ran.
    @ViewBuilder
    private var siteSearchButtons: some View {
        let browsers = model.plugins.browsers(for: category)
        if !searched.isEmpty, !browsers.isEmpty {
            HStack {
                ForEach(browsers, id: \.id) { call in
                    if let url = call.browseURL(for: searched) {
                        Button("Search on \(call.manifest.name)", systemImage: "safari") { siteSearch = BrowserRequest(url: url) }
                    }
                }
            }
        }
    }

    private func searchByName(_ query: String) {
        isNameSearch = true
        if let newznab = category.newznabCategory {
            releases.search(.text(query, category: newznab), in: category, model: model)
        }
        pluginSearch.search(query, category: category, calls: model.plugins.calls(.search, category: category))
    }

    /// The category's metadata services; nothing found (or a category without them) goes to the indexers by name.
    private func searchCovers(_ query: String) {
        let category = category
        guard [.books, .audiobooks, .music, .games].contains(category) else { return searchByName(query) }
        isSearching = true
        Task {
            let found: [CoverResult]
            switch category {
            case .music:
                found = ((try? await model.musicMetadata.search(query)) ?? []).map(CoverResult.init)
            case .games:
                found = ((try? await model.gameMetadata.search(query)) ?? []).map(CoverResult.init)
            default:
                let format: BookFormat = category == .audiobooks ? .audiobook : .ebook
                let books = BookSummary.unique((try? await model.library.searchBooks(query, format: format)) ?? [])
                found = books.map { CoverResult(book: $0, format: format) }
            }
            guard self.category == category, searched == query else { return }
            covers = found
            isSearching = false
            if found.isEmpty { searchByName(query) }
        }
    }

    private func search(_ words: String) {
        message = nil
        typeFilter = nil
        covers = []
        isNameSearch = false
        releases.clear()
        pluginSearch.clear()
        let query = words.trimmingCharacters(in: .whitespacesAndNewlines)
        searched = query
        router.searchText = query
        suggestions.clear()
        guard !query.isEmpty else { return }
        // A movie's or series' page (IMDb, Apple TV, Letterboxd…): open that title.
        if SourceDetector.sources(in: query).isEmpty, let link = TitleLink.first(in: query) {
            searched = ""
            router.searchText = ""
            Task { await model.openTitle(link) }
            return
        }
        // A magnet, a link or an info hash typed or pasted into the field: the add sheet, not a search.
        if MacSourceIntake.add(text: query, using: model) {
            searched = ""
            router.searchText = ""
            return
        }
        home.remember(query, category: category)
        guard category == .media else { return searchCovers(query) }
        guard model.addonSet.canSearch else {
            message = "Add a TMDB key or a Stremio addon that can search (for example AIOMetadata or Cinemeta) in Settings."
            return
        }
        isSearching = true
        results = []
        Task {
            do {
                results = try await model.addonSet.search(query)
            } catch {
                message = error.localizedDescription
            }
            isSearching = false
        }
    }
}

/// Behind the field: a backdrop (the hovered poster's, else the newest title's), blurred and fading into the window
/// (Apple TV style), cross-fading when it changes; a soft wash of the accent colour when there is none. The blur is
/// drawn by the GPU and images come from `ImageCache`, so a change costs one fade.
private struct HeroBackdrop: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.18)
            if let url {
                CachedImage(url: url) { Color.clear }
                    .blur(radius: 30)
                    .opacity(0.55)
                    .id(url)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: url)
        .frame(height: 420)
        .mask(LinearGradient(colors: [.black, .black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A search result: poster, name, year and kind.
private struct ResultCard: View {
    let media: MediaSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PosterImage(url: media.poster)
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(2 / 3, contentMode: .fit)
            Text(media.name).scaledFont(.callout, weight: .medium).lineLimit(1)
            HStack(spacing: 4) {
                if let year = media.releaseInfo { Text(year) }
                Text(media.type == .movie ? "Movie" : "Series")
            }
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .help(media.name)
    }
}

/// A book, album or game from a metadata service, as a search result.
struct CoverResult: Identifiable {
    let target: ReleaseTarget
    let id: String
    let subtitle: String?

    init(book: BookSummary, format: BookFormat) {
        target = .book(book, format)
        id = "book:\(book.id)"
        subtitle = [book.authors.first, book.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    init(_ album: AlbumSummary) {
        target = .album(album)
        id = "album:\(album.id)"
        subtitle = [album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
    }

    init(_ game: GameSummary) {
        target = .game(game)
        id = "game:\(game.id)"
        subtitle = ([game.year.map(String.init)] + game.platforms.prefix(2).map(\.displayName)).compactMap { $0 }.joined(separator: " · ")
    }
}

/// A cover with its name, at the cover's own ratio and the grid's width.
private struct CoverResultCard: View {
    let cover: CoverResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CachedImage(url: cover.target.cover) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Text(cover.target.title).scaledFont(.caption, weight: .semibold).multilineTextAlignment(.center).padding(6)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .aspectRatio(cover.target.ratio, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 6))
            Text(cover.target.title).scaledFont(.callout, weight: .medium).lineLimit(1)
            if let subtitle = cover.subtitle, !subtitle.isEmpty {
                Text(subtitle).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .help(cover.target.title)
    }
}
