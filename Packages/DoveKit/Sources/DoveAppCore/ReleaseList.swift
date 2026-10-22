import DoveKit
import Foundation
import Observation

/// Releases from Dove's own indexers, found by name (Search › Other categories) or for one book: the search,
/// its filters (type, private, who found it; the book kind and format for books) and adding a row.
@MainActor @Observable
public final class ReleaseList {
    public private(set) var groups: [StreamGroup] = [] { didSet { derived = Derived() } }
    public private(set) var isSearching = false
    public var message: String?
    public private(set) var busy: Set<StreamGroup.ID> = []
    /// Type, private, who found it: for this session only.
    public var filter: SourceFilter = {
        var filter = SourceFilter()
        filter.sort = .addon
        return filter
    }() { didSet { derived = Derived() } }
    /// Books and Audiobooks: show the other kind the indexers filed in the category too.
    public var showOtherBookKind = false { didSet { derived = Derived() } }
    /// Books and Audiobooks: only releases that name this format.
    public var bookFormat: BookFileFormat? { didSet { derived = Derived() } }
    /// Music: only releases that name this format (FLAC, Hi-Res, MP3…).
    public var musicFormat: MusicFileFormat? { didSet { derived = Derived() } }
    /// Games: only releases for this platform (from the indexer's console subcategory or the name).
    public var gamePlatform: GamePlatform? { didSet { derived = Derived() } }
    /// A book's screen: the rest of the indexers' answer, not this book.
    public var showOtherBooks = false { didSet { derived = Derived() } }

    /// The category searched, for the book kind split.
    public private(set) var category: SearchCategory = .all { didSet { derived = Derived() } }

    /// The splits and filters below, built once per change. Each reads release names (book kind, formats), and
    /// views read them several times a redraw, the search field's on every keystroke.
    private struct Derived {
        public var kindSplit: (matching: [StreamGroup], other: [StreamGroup])?
        public var bookSplit: (thisBook: [StreamGroup], other: [StreamGroup])?
        public var visible: [StreamGroup]?
        public var formats: [BookFileFormat]?
        public var musicFormats: [MusicFileFormat]?
        public var gamePlatforms: [GamePlatform]?
    }
    @ObservationIgnored private var derived = Derived()

    /// The cached value, or a fresh one. Reads what the values are built from first, so a view stays observing
    /// them even when the cache answers.
    private func cached<Value>(_ path: WritableKeyPath<Derived, Value?>, build: () -> Value) -> Value {
        _ = (groups, filter, showOtherBookKind, bookFormat, musicFormat, gamePlatform, showOtherBooks, category)
        if let value = derived[keyPath: path] { return value }
        let value = build()
        derived[keyPath: path] = value
        return value
    }
    /// Set on a book's screen: releases of this book come first.
    public let book: (summary: BookSummary, format: BookFormat)?
    /// Set on an album's screen, the same way.
    public let album: AlbumSummary?
    /// Set on a game's screen, the same way.
    public let game: GameSummary?

    public init(book: BookSummary? = nil, format: BookFormat = .ebook, album: AlbumSummary? = nil, game: GameSummary? = nil) {
        self.book = book.map { ($0, format) }
        self.album = album
        self.game = game
    }

    /// A book's, album's or game's screen: the rest of the answer is behind "Show N other results".
    public var isForOneTitle: Bool { book != nil || album != nil || game != nil }

    public var isEmpty: Bool { groups.isEmpty }

    public func clear() {
        groups = []
        message = nil
        showOtherBookKind = false
        bookFormat = nil
        musicFormat = nil
        gamePlatform = nil
        showOtherBooks = false
    }

    // MARK: Filtering

    /// Books searches hide audiobooks the indexers filed under Books, and the other way round (`BookRelease`).
    public var kindSplit: (matching: [StreamGroup], other: [StreamGroup]) {
        cached(\.kindSplit) {
            guard let newznab = category.newznabCategory else { return (groups, []) }
            return StreamGroup.splitByBookKind(groups, for: newznab)
        }
    }

    /// The right kind (and, when shown, the other one).
    private var ofKind: [StreamGroup] {
        kindSplit.matching + (showOtherBookKind ? kindSplit.other : [])
    }

    /// On a book's, album's or game's screen: its releases, and the rest.
    public var bookSplit: (thisBook: [StreamGroup], other: [StreamGroup]) {
        cached(\.bookSplit) {
            if let game {
                let split = StreamGroup.split(ofKind, for: game)
                return (split.thisGame, split.other)
            }
            if let album {
                let split = StreamGroup.split(ofKind, for: album)
                return (split.thisAlbum, split.other)
            }
            guard let book else { return (ofKind, []) }
            return StreamGroup.split(ofKind, for: book.summary, format: book.format)
        }
    }

    /// Platforms of the shown game results, for the chips.
    public var gamePlatforms: [GamePlatform] {
        cached(\.gamePlatforms) {
            guard category == .games else { return [] }
            let groups = bookSplit.thisBook + (showOtherBooks ? bookSplit.other : [])
            let found = Set(groups.compactMap { GamePlatform.of(release: $0.title, category: $0.category) })
            return GamePlatform.allCases.filter(found.contains)
        }
    }

    /// Formats the shown music results name, for the chips.
    public var musicFormats: [MusicFileFormat] {
        cached(\.musicFormats) {
            guard category == .music else { return [] }
            let groups = bookSplit.thisBook + (showOtherBooks ? bookSplit.other : [])
            return Set(groups.flatMap { MusicFileFormat.formats(in: $0.title) }).sorted()
        }
    }

    /// Formats the shown book results name, for the chips.
    public var formats: [BookFileFormat] {
        cached(\.formats) {
            guard category == .books || category == .audiobooks else { return [] }
            let groups = bookSplit.thisBook + (showOtherBooks ? bookSplit.other : [])
            return Set(groups.flatMap { BookRelease($0).formats }).sorted()
        }
    }

    public var visible: [StreamGroup] {
        cached(\.visible) {
            var shown = bookSplit.thisBook + (showOtherBooks ? bookSplit.other : [])
            if let bookFormat { shown = shown.filter { BookRelease($0).formats.contains(bookFormat) } }
            if let musicFormat { shown = shown.filter { MusicFileFormat.formats(in: $0.title).contains(musicFormat) } }
            if let gamePlatform { shown = shown.filter { GamePlatform.of(release: $0.title, category: $0.category) == gamePlatform } }
            return filter.apply(to: shown)
        }
    }

    // MARK: Search

    /// Through the indexers picked in Sources for the category. Same release from several indexers: one row.
    /// Rows show at once; then TorBox/Offcloud say which torrents they have cached, and those move up.
    public func search(_ query: NewznabQuery, in category: SearchCategory, model: AppModel) {
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

    public func canAdd(_ group: StreamGroup, model: AppModel) -> Bool {
        group.kind == .usenet ? model.usenetBackend != nil : !model.backends(usenet: false).isEmpty
    }

    /// Adds through the priority order (NZBs: the Usenet priority; torrents: services that have it
    /// cached first, then the debrid order); "Download only" fetches every file.
    public func add(_ group: StreamGroup, model: AppModel) {
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
                    AddedHint(releaseName: group.releaseName, book: book?.summary, album: album, game: game),
                    backend: result.backend, itemIDs: result.itemIDs, infoHash: group.infoHash
                )
                // The indexer knows better than the name: adult releases are often unmarked, audiobooks are
                // often bare "Author - Title" folders of mp3s. A book's screen knows which format it searched.
                if let book {
                    model.library.setKind(book.format == .audiobook ? .audiobooks : .books, backend: result.backend, itemID: result.itemID)
                } else if album != nil {
                    model.library.setKind(.music, backend: result.backend, itemID: result.itemID)
                } else if game != nil {
                    model.library.setKind(.games, backend: result.backend, itemID: result.itemID)
                } else if kind == .adult || kind == .audiobooks || kind == .games {
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
