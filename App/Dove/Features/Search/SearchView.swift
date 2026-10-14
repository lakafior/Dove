import DoveKit
import SwiftUI

/// The smart field: a magnet, info hash, .torrent/.nzb URL or hoster link opens the add sheet;
/// anything else searches titles through the user's Stremio addons, or, in Other, names through Dove's
/// own Newznab indexers in the picked category (software, music, books…). Movie and series searches never
/// see those results: indexers are asked for Movies/TV only there.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var pendingSources: SourceBatch?
    @State private var message: String?
    @State private var results: [MediaSummary] = []
    @State private var isSearching = false
    @State private var typeFilter: MediaType?
    @AppStorage("searchScope") private var scope: SearchScope = .media
    @AppStorage("otherCategory") private var category: NewznabCategory = .all
    @State private var otherResults: [StreamGroup] = []
    @State private var busy: Set<StreamGroup.ID> = []
    /// Search › Other's own filter (type, private, who found it), for this session only.
    @State var otherFilter: SourceFilter = {
        var filter = SourceFilter()
        filter.sort = .addon
        return filter
    }()
    @State var showOtherFilters = false
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

    /// Results (or a search on its way, or why there are none) replace the home screen; clearing the field
    /// brings it back.
    private var showsResults: Bool {
        isSearching || !results.isEmpty || !otherResults.isEmpty || (message != nil && !text.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Group {
                if showsResults {
                    resultsList
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if pasteboardHasContent, pasteboardChange != answeredChange {
                                clipboardBanner.padding(.horizontal)
                            }
                            if let message {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal)
                            }
                            HomeView(home: home) { search in
                                text = search.text
                                // A scope change searches by itself (`onChange(of: scope)`).
                                if scope == search.scope { handleSubmit() } else { scope = search.scope }
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
                prompt: scope == .media ? "Title, magnet or link" : "Name, magnet or link"
            )
            .searchScopes($scope) {
                ForEach(SearchScope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit(of: .search, handleSubmit)
            .toolbar {
                if scope == .other {
                    ToolbarItem(placement: .topBarTrailing) { categoryMenu }
                }
            }
            .navigationDestination(for: MediaSummary.self) { MediaDetailView(item: $0) }
            .navigationDestination(for: TitleRoute.self) { LibraryTitleView(titleID: $0.id) }
            .navigationDestination(for: ShelfItem.self) { LibraryItemView(item: $0.item) }
            // The field's clear button and Cancel empty the text: back to the home screen.
            .onChange(of: text) {
                if text.isEmpty { clearResults() }
            }
            // Same words, other scope or category: search again rather than leave stale results.
            .onChange(of: scope) {
                clearResults()
                if !text.isEmpty { handleSubmit() }
            }
            .onChange(of: category) {
                otherResults = []
                if scope == .other, !text.isEmpty { handleSubmit() }
            }
            .onAppear(perform: checkPasteboard)
            .onChange(of: scenePhase) { if scenePhase == .active { checkPasteboard() } }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in checkPasteboard() }
            .sheet(isPresented: $showOtherFilters) { otherFilterSheet }
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
            if isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            }
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if scope == .other, !otherResults.isEmpty {
                otherResultsSection
            }
            if scope == .media, !results.isEmpty {
                Section {
                    ForEach(visibleResults) { item in
                        NavigationLink(value: item) { MediaRow(item: item) }
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

    /// Search › Other: which Newznab category to search (adult only when shown).
    private var categoryMenu: some View {
        Menu {
            Picker("Category", selection: $category) {
                ForEach(NewznabCategory.allCases.filter { $0 != .adult || model.showAdult }, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
        } label: {
            Label(category.displayName, systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
        }
    }

    private func clearResults() {
        results = []
        otherResults = []
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
        let sources = SourceDetector.sources(in: trimmed)
        if !sources.isEmpty {
            results = []
            pendingSources = SourceBatch(sources)
        } else {
            text = trimmed
            handleSubmit()
        }
    }

    private func handleSubmit() {
        message = nil
        let sources = SourceDetector.sources(in: text)
        if !sources.isEmpty {
            results = []
            pendingSources = SourceBatch(sources)
            return
        }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        home.remember(query, scope: scope)
        if scope == .other { return searchOther(query) }
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

// MARK: - Other

extension SearchView {
    @ViewBuilder
    var otherResultsSection: some View {
        @Bindable var model = model
        Section {
            Toggle("Download only", isOn: $model.downloadOnly)
            Button {
                showOtherFilters = true
            } label: {
                Label(
                    otherFilter.isActive
                        ? "Showing \(visibleOtherResults.count) of \(otherResults.count) · filters on"
                        : "Filter and sort",
                    systemImage: otherFilter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                )
            }
            ForEach(visibleOtherResults) { group in
                OtherResultRow(
                    group: group,
                    isBusy: busy.contains(group.id),
                    downloadOnly: model.downloadOnly,
                    onAdd: canAdd(group) ? { addOther(group) } : nil
                )
            }
        } footer: {
            if visibleOtherResults.contains(where: { !canAdd($0) }) {
                Text("NZBs need nzbdav or Usenet on TorBox, Offcloud or Premiumize, torrents a debrid service: set them up in Settings.")
            }
        }
    }

    var visibleOtherResults: [StreamGroup] {
        otherFilter.apply(to: otherResults)
    }

    var otherFilterSheet: some View {
        SourceFilterSheet(
            filter: $otherFilter,
            groups: otherResults,
            dimensions: [.type, .privacy, .provider, .tracker, .cached],
            sorts: [.addon, .seeders, .newest, .sizeDescending, .sizeAscending],
            showsAppleTV: false
        )
        .presentationDetents([.medium, .large])
    }

    /// Words in the picked category, through Dove's own indexers. Same release from several indexers: one row.
    /// Rows show at once; then TorBox/Offcloud say which torrents they have cached, and those move up.
    func searchOther(_ query: String) {
        guard !model.newznab.isEmpty else {
            message = "Add a Newznab or Torznab indexer in Settings › Search › Indexers to search beyond movies and series."
            return
        }
        isSearching = true
        otherResults = []
        let search = model.newznab
        // A remembered Adult category does not survive hiding adult content.
        let category = category == .adult && !model.showAdult ? NewznabCategory.all : category
        let showAdult = model.showAdult
        let usenet = model.usenetBackend
        let checkers = model.cacheCheckers
        Task {
            let found = await search.search(.text(query, category: category)).routed(to: usenet)
            // Adult results stay out unless shown: indexer category 6000, or a marker in the name.
            let candidates = showAdult ? found.candidates : found.candidates.filter { candidate in
                candidate.category.map(ContentKind.init(newznabCategory:)) != .adult && !ContentClassifier.isAdult(name: candidate.title)
            }
            otherResults = StreamGroup.group(candidates)
            let failures = found.failures.joined(separator: "\n")
            message = otherResults.isEmpty
                ? (failures.isEmpty ? "Nothing found." : failures)
                : (failures.isEmpty ? nil : failures)
            isSearching = false
            guard !checkers.isEmpty, otherResults.contains(where: { $0.infoHash != nil }) else { return }
            let checked = await CacheChecker.annotate(otherResults, using: checkers)
            // Stable: cached torrents first, the indexers' order otherwise.
            otherResults = checked.filter { $0.kind != .usenet && $0.isCached } + checked.filter { !($0.kind != .usenet && $0.isCached) }
        }
    }

    func canAdd(_ group: StreamGroup) -> Bool {
        group.kind == .usenet ? model.usenetBackend != nil : !model.backends(usenet: false).isEmpty
    }

    /// Adds through the priority order (NZBs: the Usenet priority; torrents: services that have it
    /// cached first, then the debrid order); "Download only" fetches every file.
    func addOther(_ group: StreamGroup) {
        guard let source = group.librarySource else { return }
        busy.insert(group.id)
        Task {
            defer { busy.remove(group.id) }
            do {
                // A Torznab result's .torrent link carries the indexer's key: fetch it here, never hand it over.
                let router = model.router(preferring: group.cachedBackends()).forPrivateTracker(group.isPrivate == true)
                // NZBs are filed by the indexer's category (audio, software, books, xxx…).
                let category = group.category.flatMap(AddCategory.init(newznabCategory:))
                let result = try await router.add(try await IndexerTorrent.prepare(source), category: category)
                // The indexer knows better than the name: adult releases are often unmarked, audiobooks are
                // often bare "Author - Title" folders of mp3s.
                if let kind = group.category.map(ContentKind.init(newznabCategory:)), kind == .adult || kind == .audiobooks {
                    model.library.setKind(kind, backend: result.backend, itemID: result.itemID)
                }
                message = model.downloadOnly
                    ? await model.startDownloadOnly(result.itemID, on: result.backend, name: group.title, pick: .allVideos)
                    : "Added to \(result.backend.displayName)."
            } catch {
                message = error.localizedDescription
            }
        }
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
