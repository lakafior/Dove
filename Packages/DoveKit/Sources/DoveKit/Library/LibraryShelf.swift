import Foundation

/// One library item with what Dove guessed from its name (and files, when the service lists them).
public struct ShelfItem: Identifiable, Sendable, Hashable {
    public let item: LibraryItem
    /// The service's name, or a readable one when the service lists a random string (`LibraryNaming`).
    public let name: String
    public let guess: MediaGuess
    public let kind: ContentKind
    /// What Dove knew when it added the item, if it did.
    public let hint: AddedHint?
    public var id: String { Self.id(backend: item.backend, itemID: item.id) }
    /// The service lists it under another (random) name than the one shown.
    public var isRenamed: Bool { name != item.name }

    /// Stable across launches and shared with the Files extension (`KindOverrides` keys).
    public static func id(backend: BackendID, itemID: LibraryItem.ID) -> String { "\(backend.rawValue)/\(itemID)" }

    /// - Parameters:
    ///   - kind: what an earlier look at the item's files established; classified from the item otherwise.
    ///   - hint: what Dove knew when it added the item: a readable name for an obfuscated one, and the title
    ///     it was found for (which makes it video even when neither name says so).
    public init(item: LibraryItem, kind: ContentKind? = nil, hint: AddedHint? = nil) {
        self.item = item
        self.hint = hint
        name = LibraryNaming.readableName(of: item, hint: hint)
        var guess = ReleaseParser.guess(name)
        if let media = hint?.media, LibraryNaming.looksObfuscated(name) {
            guess = MediaGuess(title: media.name, year: media.releaseInfo.flatMap { Int($0.prefix(4)) }, type: media.type)
        }
        self.guess = guess
        let classified = ContentClassifier.classify(name: name, files: item.files)
        self.kind = kind ?? item.kindHint ?? (hint?.media != nil && classified == .other ? .video : classified)
    }
}

/// Everything the user has of one title, across debrids: "Severance" with its season packs and episodes.
public struct LibraryTitle: Identifiable, Sendable, Hashable {
    public let id: String
    public let guess: MediaGuess
    public var media: MediaSummary?
    public var items: [ShelfItem]

    public var name: String { media?.name ?? guess.title }
    public var type: MediaType { media?.type ?? guess.type }
    public var year: String? { media?.releaseInfo ?? guess.year.map(String.init) }
    public var backends: [BackendID] {
        Array(Set(items.map(\.item.backend))).sorted { $0.rawValue < $1.rawValue }
    }
    public var latestAdded: Date? { items.compactMap(\.item.addedAt).max() }
    public var size: Int64 { items.compactMap(\.item.size).reduce(0, +) }

    /// The least finished state among its items, so a title shows "downloading" until everything is ready.
    public var status: LibraryFilter.Status { LibraryFilter.Status(least: items) }

    /// Items grouped by season for series. Multi-season and complete packs (and items without a season)
    /// come first under nil, then "Season 1", "Season 2"…, episode order within.
    public var seasons: [(season: Int?, items: [ShelfItem])] {
        let grouped = Dictionary(grouping: items) { item -> Int? in
            switch item.guess.scope {
            case .seasons, .complete, nil: nil
            case .season, .episodes: item.guess.season
            }
        }
        return grouped.keys
            .sorted { ($0 ?? .min) < ($1 ?? .min) }
            .map { season in
                (season, grouped[season]!.sorted { ($0.guess.episode ?? -1, $0.name) < ($1.guess.episode ?? -1, $1.name) })
            }
    }
}

extension LibraryTitle {
    /// What the library holds of a series, for its card: "Complete", "S1–3", "S1–2 +3 ep", "S2E05", "S2 · 4 ep".
    public var coverage: String? {
        guard type == .series else { return nil }
        let scopes = items.compactMap(\.guess.scope)
        if scopes.contains(.complete) { return "Complete" }
        var packSeasons = Set<Int>()
        var episodes = Set<[Int]>()
        for scope in scopes {
            switch scope {
            case .season(let season): packSeasons.insert(season)
            case .seasons(let first, let last): packSeasons.formUnion(first...last)
            case .episodes(let season, let numbers): numbers.forEach { episodes.insert([season, $0]) }
            case .complete: break
            }
        }
        let loose = episodes.filter { !packSeasons.contains($0[0]) }
        if !packSeasons.isEmpty {
            let packs = "S" + Self.ranges(packSeasons)
            return loose.isEmpty ? packs : "\(packs) +\(loose.count) ep"
        }
        guard let first = loose.first else { return nil }
        let seasons = Set(loose.map { $0[0] })
        if loose.count == 1 { return SeriesScope.episodes(season: first[0], [first[1]]).label }
        return seasons.count == 1 ? "S\(first[0]) · \(loose.count) ep" : "\(loose.count) ep"
    }

    /// 1,2,3,5 → "1–3, 5".
    public static func ranges(_ numbers: Set<Int>) -> String {
        var parts: [String] = []
        var run: [Int] = []
        for number in numbers.sorted() {
            if let last = run.last, number != last + 1 {
                parts.append(run.count > 1 ? "\(run[0])–\(last)" : "\(run[0])")
                run = []
            }
            run.append(number)
        }
        if let first = run.first, let last = run.last { parts.append(first == last ? "\(first)" : "\(first)–\(last)") }
        return parts.joined(separator: ", ")
    }
}

/// Every release of one book in one format (an ebook and its audiobook are two), across services.
public struct BookTitle: Identifiable, Sendable, Hashable {
    public let id: String
    public let guess: BookGuess
    public var book: BookSummary?
    public var items: [ShelfItem]

    public var format: BookFormat { guess.format }
    public var name: String { book?.title ?? guess.title }
    public var author: String? { book?.authors.first ?? guess.author }
    public var year: String? { (book?.year ?? guess.year).map(String.init) }
    public var backends: [BackendID] {
        Array(Set(items.map(\.item.backend))).sorted { $0.rawValue < $1.rawValue }
    }
    public var latestAdded: Date? { items.compactMap(\.item.addedAt).max() }
    public var size: Int64 { items.compactMap(\.item.size).reduce(0, +) }
    public var status: LibraryFilter.Status { LibraryFilter.Status(least: items) }
}

/// Every release of one album (FLAC and MP3, a reissue), across services.
public struct AlbumTitle: Identifiable, Sendable, Hashable {
    public let id: String
    public let guess: AlbumGuess
    public var album: AlbumSummary?
    public var items: [ShelfItem]

    public var name: String { album?.title ?? guess.title }
    public var artist: String? { album?.artist ?? guess.artist }
    public var year: String? { (album?.year ?? guess.year).map(String.init) }
    public var backends: [BackendID] {
        Array(Set(items.map(\.item.backend))).sorted { $0.rawValue < $1.rawValue }
    }
    public var latestAdded: Date? { items.compactMap(\.item.addedAt).max() }
    public var size: Int64 { items.compactMap(\.item.size).reduce(0, +) }
    public var status: LibraryFilter.Status { LibraryFilter.Status(least: items) }
}

/// One artist's albums in the library.
public struct ArtistShelf: Identifiable, Sendable, Hashable {
    /// The artist's name, normalized: the same artist spelled "AC/DC" and "ACDC" is one shelf.
    public let id: String
    public var name: String
    public var albums: [AlbumTitle]

    /// The newest album's cover stands for the artist.
    public var cover: URL? { albums.lazy.compactMap(\.album?.cover).first }
    public var latestAdded: Date? { albums.compactMap(\.latestAdded).max() }
}

public enum LibraryShelf {
    /// Groups items by matched title (several releases of one show share its metadata ID),
    /// falling back to the guessed title when there is no match. Newest first.
    public static func titles(_ items: [ShelfItem], matches: [String: MediaSummary]) -> [LibraryTitle] {
        var titles: [String: LibraryTitle] = [:]
        var order: [String] = []
        for item in items where item.kind == .video {
            let media = matches[item.guess.key]
            let id = media.map { "media:\($0.type.rawValue):\($0.id)" } ?? "guess:\(item.guess.key)"
            if titles[id] == nil {
                titles[id] = LibraryTitle(id: id, guess: item.guess, media: media, items: [])
                order.append(id)
            }
            titles[id]!.items.append(item)
        }
        return order.compactMap { titles[$0] }
            .sorted { ($0.latestAdded ?? .distantPast) > ($1.latestAdded ?? .distantPast) }
    }

    /// Books and audiobooks grouped like titles: by matched book, else by guessed author and title. Newest first.
    public static func books(_ items: [ShelfItem], matches: [String: BookSummary]) -> [BookTitle] {
        var books: [String: BookTitle] = [:]
        var order: [String] = []
        for item in items {
            guard let guess = item.bookGuess else { continue }
            let book = matches[guess.key]
            let id = book.map { "book:\(guess.format.rawValue):\($0.id)" } ?? "guess:\(guess.key)"
            if books[id] == nil {
                books[id] = BookTitle(id: id, guess: guess, book: book, items: [])
                order.append(id)
            }
            books[id]!.items.append(item)
        }
        return order.compactMap { books[$0] }
            .sorted { ($0.latestAdded ?? .distantPast) > ($1.latestAdded ?? .distantPast) }
    }

    /// Music grouped by matched album, else by guessed artist and title. Newest first.
    public static func albums(_ items: [ShelfItem], matches: [String: AlbumSummary]) -> [AlbumTitle] {
        var albums: [String: AlbumTitle] = [:]
        var order: [String] = []
        for item in items {
            guard let guess = item.albumGuess else { continue }
            let album = matches[guess.key]
            let id = album.map { "album:\($0.id)" } ?? "guess:\(guess.key)"
            if albums[id] == nil {
                albums[id] = AlbumTitle(id: id, guess: guess, album: album, items: [])
                order.append(id)
            }
            albums[id]!.items.append(item)
        }
        return order.compactMap { albums[$0] }
            .sorted { ($0.latestAdded ?? .distantPast) > ($1.latestAdded ?? .distantPast) }
    }

    /// Albums by artist (the matched album's first artist, else the guessed one; "Unknown Artist" without either),
    /// artists with the newest album first, their albums newest year first.
    public static func artists(_ albums: [AlbumTitle]) -> [ArtistShelf] {
        var artists: [String: ArtistShelf] = [:]
        var order: [String] = []
        for album in albums {
            let name = album.album?.artists.first ?? album.guess.artist ?? "Unknown Artist"
            let id = MediaGuess.normalize(name).isEmpty ? name : MediaGuess.normalize(name)
            if artists[id] == nil {
                artists[id] = ArtistShelf(id: id, name: name, albums: [])
                order.append(id)
            }
            artists[id]!.albums.append(album)
        }
        return order.compactMap { artists[$0] }
            .map { artist in
                var artist = artist
                artist.albums.sort { (Int($0.year ?? "") ?? 0) > (Int($1.year ?? "") ?? 0) }
                return artist
            }
            .sorted { ($0.latestAdded ?? .distantPast) > ($1.latestAdded ?? .distantPast) }
    }

    /// Everything that is neither video, a book nor music, newest first: listed by name, no titles or covers.
    public static func others(_ items: [ShelfItem]) -> [ShelfItem] {
        items.filter { $0.kind != .video && $0.kind != .music && BookFormat(kind: $0.kind) == nil }
    }
}

/// Library filters: which debrids, what kind of content, status, and a text query.
public struct LibraryFilter: Equatable, Sendable {
    /// Movies and series split video; the other kinds map one to one.
    public enum Category: String, CaseIterable, Sendable {
        case movies, series, music, books, audiobooks, software, adult, other

        public var title: String {
            switch self {
            case .movies: "Movies"
            case .series: "Series"
            case .music: "Music"
            case .books: "Books"
            case .audiobooks: "Audiobooks"
            case .software: "Software"
            case .adult: "Adult"
            case .other: "Other"
            }
        }

        public func contains(_ item: ShelfItem) -> Bool {
            switch self {
            case .movies: item.kind == .video && item.guess.type == .movie
            case .series: item.kind == .video && item.guess.type == .series
            case .music: item.kind == .music
            case .books: item.kind == .books
            case .audiobooks: item.kind == .audiobooks
            case .software: item.kind == .software
            case .adult: item.kind == .adult
            case .other: item.kind == .other
            }
        }
    }

    public enum Status: String, CaseIterable, Sendable {
        case ready, active, failed

        public init(of status: LibraryItem.Status) {
            switch status {
            case .ready: self = .ready
            case .queued, .awaitingFileSelection, .downloading: self = .active
            case .failed: self = .failed
            }
        }

        /// The least finished state among items: failed, then downloading, then ready.
        init(least items: [ShelfItem]) {
            let states = Set(items.map { Status(of: $0.item.status) })
            self = states.contains(.failed) ? .failed : states.contains(.active) ? .active : .ready
        }

        public var title: String {
            switch self {
            case .ready: "Ready"
            case .active: "Downloading"
            case .failed: "Failed"
            }
        }
    }

    /// Empty means every backend.
    public var backends: Set<BackendID> = []
    public var category: Category?
    public var status: Status?
    public var query = ""

    public init() {}

    public var isActive: Bool {
        !backends.isEmpty || category != nil || status != nil
    }

    public func matches(_ item: ShelfItem, title: String? = nil) -> Bool {
        if !backends.isEmpty && !backends.contains(item.item.backend) { return false }
        if let category, !category.contains(item) { return false }
        if let status, Status(of: item.item.status) != status { return false }
        return matchesQuery(item.name) || matchesQuery(item.item.name) || title.map(matchesQuery) == true
    }

    /// Keeps titles with at least one matching item, trimmed to those items.
    public func apply(to titles: [LibraryTitle]) -> [LibraryTitle] {
        titles.compactMap { title in
            switch category {
            case nil: break
            case .movies: if title.type != .movie { return nil }
            case .series: if title.type != .series { return nil }
            case .music, .books, .audiobooks, .software, .adult, .other: return nil
            }
            var title = title
            title.items = title.items.filter { keeps($0, names: [title.name]) }
            return title.items.isEmpty ? nil : title
        }
    }

    /// The same for books: the category picks the format; the query also finds the author.
    public func apply(to books: [BookTitle]) -> [BookTitle] {
        books.compactMap { book in
            switch category {
            case nil: break
            case .books: if book.format != .ebook { return nil }
            case .audiobooks: if book.format != .audiobook { return nil }
            case .movies, .series, .music, .software, .adult, .other: return nil
            }
            var book = book
            book.items = book.items.filter { keeps($0, names: [book.name, book.author].compactMap { $0 }) }
            return book.items.isEmpty ? nil : book
        }
    }

    /// The same for albums: only Music (or no category) keeps them; the query also finds the artist.
    public func apply(to albums: [AlbumTitle]) -> [AlbumTitle] {
        albums.compactMap { album in
            if let category, category != .music { return nil }
            var album = album
            album.items = album.items.filter { keeps($0, names: [album.name, album.artist].compactMap { $0 }) }
            return album.items.isEmpty ? nil : album
        }
    }

    /// An item of a title or book passes the service and status filters, and the query matches it or the title.
    private func keeps(_ item: ShelfItem, names: [String]) -> Bool {
        if !backends.isEmpty && !backends.contains(item.item.backend) { return false }
        if let status, Status(of: item.item.status) != status { return false }
        return matchesQuery(item.name) || matchesQuery(item.item.name) || names.contains(where: matchesQuery)
    }

    public func apply(to items: [ShelfItem]) -> [ShelfItem] {
        items.filter { matches($0) }
    }

    private func matchesQuery(_ text: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return text.localizedCaseInsensitiveContains(query)
            || MediaGuess.normalize(text).contains(MediaGuess.normalize(query))
    }
}

public enum LibraryLoader {
    public struct Result: Sendable {
        public var items: [ShelfItem]
        public var failures: [String]
        /// Services that did not answer; their items are missing from `items`, not gone.
        public var failed: Set<BackendID> = []
    }

    /// Every backend's items in parallel, newest first. A failing backend is reported, the rest still load.
    public static func load(_ backends: [any LibraryBackend]) async -> Result {
        await withTaskGroup(of: (BackendID, Swift.Result<[LibraryItem], any Error>).self) { group in
            for backend in backends {
                group.addTask {
                    do { return (backend.id, .success(try await backend.items())) }
                    catch { return (backend.id, .failure(error)) }
                }
            }
            var items: [ShelfItem] = []
            var failures: [String] = []
            var failed: Set<BackendID> = []
            for await (id, result) in group {
                switch result {
                case .success(let list): items += list.map { ShelfItem(item: $0) }
                case .failure(let error):
                    failed.insert(id)
                    failures.append("\(id.displayName): \(error.localizedDescription)")
                }
            }
            items.sort { ($0.item.addedAt ?? .distantPast) > ($1.item.addedAt ?? .distantPast) }
            return Result(items: items, failures: failures.sorted(), failed: failed)
        }
    }
}
