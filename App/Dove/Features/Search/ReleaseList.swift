import DoveKit
import SwiftUI

/// Releases from Dove's own indexers, found by name (Search › Other categories) or for one book: the search,
/// its filters (type, private, who found it; the book kind and format for books) and adding a row.
@MainActor @Observable
final class ReleaseList {
    private(set) var groups: [StreamGroup] = []
    private(set) var isSearching = false
    var message: String?
    private(set) var busy: Set<StreamGroup.ID> = []
    /// Type, private, who found it: for this session only.
    var filter: SourceFilter = {
        var filter = SourceFilter()
        filter.sort = .addon
        return filter
    }()
    /// Books and Audiobooks: show the other kind the indexers filed in the category too.
    var showOtherBookKind = false
    /// Books and Audiobooks: only releases that name this format.
    var bookFormat: BookFileFormat?
    /// A book's screen: the rest of the indexers' answer, not this book.
    var showOtherBooks = false

    /// The category searched, for the book kind split.
    private(set) var category: SearchCategory = .all
    /// Set on a book's screen: releases of this book come first.
    let book: (summary: BookSummary, format: BookFormat)?
    /// Set on an album's screen, the same way.
    let album: AlbumSummary?

    init(book: BookSummary? = nil, format: BookFormat = .ebook, album: AlbumSummary? = nil) {
        self.book = book.map { ($0, format) }
        self.album = album
    }

    /// A book's or album's screen: the rest of the answer is behind "Show N other results".
    var isForOneTitle: Bool { book != nil || album != nil }

    var isEmpty: Bool { groups.isEmpty }

    func clear() {
        groups = []
        message = nil
        showOtherBookKind = false
        bookFormat = nil
        showOtherBooks = false
    }

    // MARK: Filtering

    /// Books searches hide audiobooks the indexers filed under Books, and the other way round (`BookRelease`).
    var kindSplit: (matching: [StreamGroup], other: [StreamGroup]) {
        guard let newznab = category.newznabCategory else { return (groups, []) }
        return StreamGroup.splitByBookKind(groups, for: newznab)
    }

    /// The right kind (and, when shown, the other one).
    private var ofKind: [StreamGroup] {
        kindSplit.matching + (showOtherBookKind ? kindSplit.other : [])
    }

    /// On a book's or album's screen: its releases, and the rest.
    var bookSplit: (thisBook: [StreamGroup], other: [StreamGroup]) {
        if let album {
            let split = StreamGroup.split(ofKind, for: album)
            return (split.thisAlbum, split.other)
        }
        guard let book else { return (ofKind, []) }
        return StreamGroup.split(ofKind, for: book.summary, format: book.format)
    }

    /// Formats the shown book results name, for the chips.
    var formats: [BookFileFormat] {
        guard category == .books || category == .audiobooks else { return [] }
        let groups = bookSplit.thisBook + (showOtherBooks ? bookSplit.other : [])
        return Set(groups.flatMap { BookRelease($0).formats }).sorted()
    }

    var visible: [StreamGroup] {
        var shown = bookSplit.thisBook + (showOtherBooks ? bookSplit.other : [])
        if let bookFormat { shown = shown.filter { BookRelease($0).formats.contains(bookFormat) } }
        return filter.apply(to: shown)
    }

    // MARK: Search

    /// Through the indexers picked in Sources for the category. Same release from several indexers: one row.
    /// Rows show at once; then TorBox/Offcloud say which torrents they have cached, and those move up.
    func search(_ query: NewznabQuery, in category: SearchCategory, model: AppModel) {
        guard !model.newznab.isEmpty else {
            message = "Add a Newznab or Torznab indexer in Settings › Search › Indexers to search beyond movies and series."
            return
        }
        let indexers = model.indexerIDs(for: category)
        guard !indexers.isEmpty else {
            groups = []
            message = "Every source is off for \(category.displayName). Turn one on in Sources."
            return
        }
        clear()
        self.category = category
        isSearching = true
        let search = model.newznab
        let showAdult = model.showAdult
        let usenet = model.usenetBackend
        let checkers = model.cacheCheckers
        Task {
            let found = await search.search(query, only: indexers).routed(to: usenet)
            // Adult results stay out unless shown: indexer category 6000, or a marker in the name.
            let candidates = showAdult ? found.candidates : found.candidates.filter { candidate in
                candidate.category.map(ContentKind.init(newznabCategory:)) != .adult && !ContentClassifier.isAdult(name: candidate.title)
            }
            groups = StreamGroup.group(candidates)
            let failures = found.failures.joined(separator: "\n")
            message = groups.isEmpty
                ? (failures.isEmpty ? "Nothing found." : failures)
                : (failures.isEmpty ? nil : failures)
            isSearching = false
            guard !checkers.isEmpty, groups.contains(where: { $0.infoHash != nil }) else { return }
            let checked = await CacheChecker.annotate(groups, using: checkers)
            // Stable: cached torrents first, the indexers' order otherwise.
            groups = checked.filter { $0.kind != .usenet && $0.isCached } + checked.filter { !($0.kind != .usenet && $0.isCached) }
        }
    }

    // MARK: Adding

    func canAdd(_ group: StreamGroup, model: AppModel) -> Bool {
        group.kind == .usenet ? model.usenetBackend != nil : !model.backends(usenet: false).isEmpty
    }

    /// Adds through the priority order (NZBs: the Usenet priority; torrents: services that have it
    /// cached first, then the debrid order); "Download only" fetches every file.
    func add(_ group: StreamGroup, model: AppModel) {
        guard let route = group.route(through: model.router(preferring: group.cachedBackends())) else { return }
        busy.insert(group.id)
        Task {
            defer { busy.remove(group.id) }
            do {
                // NZBs are filed by the indexer's category (audio, software, books, xxx…), audiobooks the
                // indexer filed under Books in audiobooks.
                let kind = group.contentKind
                let category = kind == .audiobooks ? .audiobooks : group.category.flatMap(AddCategory.init(newznabCategory:))
                // A Torznab result's .torrent link carries the indexer's key: fetch it here, never hand it over.
                // A private release a service has cached goes there as a magnet (`AddRoute`).
                let result = try await route.router.add(try await IndexerTorrent.prepare(route.source), category: category)
                // From a book's screen: the book it was found for, so the Library shows it without a search.
                model.library.recordAdded(
                    AddedHint(releaseName: group.releaseName, book: book?.summary),
                    backend: result.backend, itemIDs: result.itemIDs, infoHash: group.infoHash
                )
                // The indexer knows better than the name: adult releases are often unmarked, audiobooks are
                // often bare "Author - Title" folders of mp3s. A book's screen knows which format it searched.
                if let book {
                    model.library.setKind(book.format == .audiobook ? .audiobooks : .books, backend: result.backend, itemID: result.itemID)
                } else if album != nil {
                    model.library.setKind(.music, backend: result.backend, itemID: result.itemID)
                } else if kind == .adult || kind == .audiobooks {
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

/// The rows of a `ReleaseList` inside a `List`: Download only, filters, format chips, the releases, and what
/// is hidden (the other book kind, other books).
struct ReleaseListSection: View {
    @Environment(AppModel.self) private var model
    @Bindable var list: ReleaseList
    var title: String?
    @State private var showFilters = false

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle("Download only", isOn: $model.downloadOnly)
            Button {
                showFilters = true
            } label: {
                Label(
                    list.filter.isActive
                        ? "Showing \(list.visible.count) of \(list.groups.count) · filters on"
                        : "Filter and sort",
                    systemImage: list.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                )
            }
            if !list.formats.isEmpty { formatBar }
            ForEach(list.visible) { group in
                OtherResultRow(
                    group: group,
                    isBusy: list.busy.contains(group.id),
                    downloadOnly: model.downloadOnly,
                    onAdd: list.canAdd(group, model: model) ? { list.add(group, model: model) } : nil
                )
            }
            let otherBooks = list.isForOneTitle ? list.bookSplit.other.count : 0
            if otherBooks > 0 {
                Button(list.showOtherBooks ? "Hide \(otherBooks) other results" : "Show \(otherBooks) other results") {
                    list.showOtherBooks.toggle()
                }
                .font(.subheadline)
            }
            if let toggle = otherKindToggle {
                Button(toggle) { list.showOtherBookKind.toggle() }
                    .font(.subheadline)
            }
        } header: {
            if let title { Text(title) }
        } footer: {
            if list.visible.contains(where: { !list.canAdd($0, model: model) }) {
                Text("NZBs need nzbdav or Usenet on TorBox, Offcloud or Premiumize, torrents a debrid service: set them up in Settings.")
            }
        }
        .sheet(isPresented: $showFilters) {
            SourceFilterSheet(
                filter: $list.filter,
                groups: list.groups,
                dimensions: [.type, .privacy, .provider, .tracker, .cached],
                sorts: [.addon, .seeders, .newest, .sizeDescending, .sizeAscending],
                showsAppleTV: false
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var otherKindToggle: String? {
        let count = list.kindSplit.other.count
        guard count > 0 else { return nil }
        let kind = list.category == .books ? (count == 1 ? "audiobook" : "audiobooks") : (count == 1 ? "ebook" : "ebooks")
        return list.showOtherBookKind ? "Hide \(count) \(kind)" : "Show \(count) \(kind) filed here"
    }

    private var formatBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", selected: list.bookFormat == nil) { list.bookFormat = nil }
                ForEach(list.formats, id: \.self) { format in
                    chip(format.displayName, selected: list.bookFormat == format) {
                        list.bookFormat = list.bookFormat == format ? nil : format
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline)
            .buttonStyle(.bordered)
            .tint(selected ? .accentColor : .secondary)
            .buttonBorderShape(.capsule)
    }
}
