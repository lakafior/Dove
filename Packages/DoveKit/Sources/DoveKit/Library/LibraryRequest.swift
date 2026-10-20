import Foundation

/// The Library narrowed by a sentence ("series from the 80s in 4K on Real-Debrid"): what the words ask for, mapped
/// by the on-device model (in the app) onto what library titles know, and checked here like `SourceRequest`: a
/// value stays only when the words name it. Titles know their kind, year, services, status and release names
/// (resolution), not their genres, so genre words are left out (`ignoresGenre` says so). Session-only, on top of
/// the filters.
public struct LibraryRequest: Equatable, Sendable {
    public var text: String
    public var category: LibraryFilter.Category?
    public var years: ClosedRange<Int>?
    public var resolutions: Set<String> = []
    public var backends: Set<BackendID> = []
    public var status: LibraryFilter.Status?
    /// Words of a title or author, looked for like the typed filter.
    public var words: String?

    public init(text: String) {
        self.text = text
    }

    /// From the model's answer. `kind`, `status` and resolutions use the names listed in the instructions; services
    /// their display names or abbreviations.
    public init(
        text: String,
        kind: String?,
        yearFrom: Int?,
        yearTo: Int?,
        resolutions: [String],
        services: [String],
        status: String?,
        words: String?
    ) {
        self.text = text
        if let kind = kind.flatMap(LibraryFilter.Category.init(rawValue:)),
           SourceRequest.mentionsAny(text, Self.kindWords[kind] ?? []) {
            category = kind
        }
        // Years need a year or a decade in the words ("1984", "80s", "lata 80"), not any digit ("4K"); one bound
        // stands for itself ("from 1999" is open-ended).
        if Self.namesYears(text) {
            let lower = yearFrom.flatMap { (1870...2100).contains($0) ? $0 : nil }
            let upper = yearTo.flatMap { (1870...2100).contains($0) ? $0 : nil }
            switch (lower, upper) {
            case let (lower?, upper?): years = min(lower, upper)...max(lower, upper)
            case let (lower?, nil): years = lower...2100
            case let (nil, upper?): years = 1870...upper
            case (nil, nil): break
            }
        }
        let known = SourceFilter.preferredOrder[.resolution] ?? []
        self.resolutions = SourceRequest.resolve(resolutions, in: .resolution, vocabulary: [.resolution: known])
            .filter { SourceRequest.mentions(text, $0, in: .resolution) }
        backends = Set(services.compactMap { service in
            BackendID.allCases.first {
                $0.displayName.caseInsensitiveCompare(service) == .orderedSame || $0.rawValue.caseInsensitiveCompare(service) == .orderedSame
            }
        }.filter { SourceRequest.mentionsAny(text, [$0.displayName, $0.rawValue] + (Self.serviceWords[$0] ?? [])) })
        if let status = status.flatMap(LibraryFilter.Status.init(rawValue:)),
           SourceRequest.mentionsAny(text, Self.statusWords[status] ?? []) {
            self.status = status
        }
        // Title words must be the user's own words, and not only a genre or a kind ("horror", "movies"): the model
        // copies those too, and no title holds them.
        if let words = words?.trimmingCharacters(in: .whitespacesAndNewlines), words.count >= 2,
           text.localizedCaseInsensitiveContains(words), !Self.onlyDescribes(words) {
            self.words = words
        }
    }

    public var isEmpty: Bool {
        category == nil && years == nil && resolutions.isEmpty && backends.isEmpty && status == nil && words == nil
    }

    /// The words named a genre, which titles do not know: said on the chip so the result is not mistaken for one.
    public var ignoresGenre: Bool {
        SourceRequest.mentionsAny(text, Self.genreWords)
    }

    /// What the request does, short, for the chip: "Series · 1980–1989 · 2160p · Real-Debrid".
    public var summary: String {
        var parts: [String] = []
        if let category { parts.append(category.title) }
        if let years { parts.append(years.upperBound == 2100 ? "from \(years.lowerBound)" : years.lowerBound == 1870 ? "until \(years.upperBound)" : "\(years.lowerBound)–\(years.upperBound)") }
        if !resolutions.isEmpty { parts.append(resolutions.sorted().joined(separator: "/")) }
        if !backends.isEmpty { parts.append(backends.map(\.displayName).sorted().joined(separator: "/")) }
        if let status { parts.append(status.title) }
        if let words { parts.append("\u{201C}\(words)\u{201D}") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Applying

    public func apply(to titles: [LibraryTitle]) -> [LibraryTitle] {
        titles.compactMap { title in
            if let category {
                guard (category == .movies && title.type == .movie) || (category == .series && title.type == .series) else { return nil }
            }
            guard keepsYear(title.year), keepsWords([title.name]) else { return nil }
            var title = title
            title.items = title.items.filter(keepsItem)
            return title.items.isEmpty ? nil : title
        }
    }

    public func apply(to books: [BookTitle]) -> [BookTitle] {
        books.compactMap { book in
            if let category {
                guard (category == .books && book.format == .ebook) || (category == .audiobooks && book.format == .audiobook) else { return nil }
            }
            guard resolutions.isEmpty, keepsYear(book.year), keepsWords([book.name, book.author].compactMap { $0 }) else { return nil }
            var book = book
            book.items = book.items.filter(keepsItem)
            return book.items.isEmpty ? nil : book
        }
    }

    public func apply(to albums: [AlbumTitle]) -> [AlbumTitle] {
        guard category == nil || category == .music, resolutions.isEmpty, years == nil else { return [] }
        return albums.compactMap { album in
            guard keepsWords([album.name, album.artist].compactMap { $0 }) else { return nil }
            var album = album
            album.items = album.items.filter(keepsItem)
            return album.items.isEmpty ? nil : album
        }
    }

    public func apply(to items: [ShelfItem]) -> [ShelfItem] {
        items.filter { item in
            (category.map { $0.contains(item) } ?? true) && keepsYear(item.guess.year.map(String.init))
                && keepsWords([item.name]) && keepsItem(item)
        }
    }

    private func keepsItem(_ item: ShelfItem) -> Bool {
        if !backends.isEmpty, !backends.contains(item.item.backend) { return false }
        if let status, LibraryFilter.Status(of: item.item.status) != status { return false }
        if !resolutions.isEmpty {
            guard let resolution = ReleaseParser.parse(item.item.name).resolution, resolutions.contains(resolution) else { return false }
        }
        return true
    }

    private func keepsYear(_ year: String?) -> Bool {
        guard let years else { return true }
        guard let year = year.flatMap({ Int($0.prefix(4)) }) else { return false }
        return years.contains(year)
    }

    private func keepsWords(_ names: [String]) -> Bool {
        guard let words else { return true }
        let wanted = MediaGuess.normalize(words)
        return names.contains { $0.localizedCaseInsensitiveContains(words) || MediaGuess.normalize($0).contains(wanted) }
    }

    // MARK: - Words

    static func onlyDescribes(_ words: String) -> Bool {
        let describing = Set(genreWords + kindWords.values.flatMap { $0 } + ["the", "a", "from", "in", "on", "with", "and", "old", "new"])
        return words.lowercased().split { !$0.isLetter && $0 != "-" }.allSatisfy { describing.contains(String($0)) }
    }

    static func namesYears(_ text: String) -> Bool {
        let patterns = [#"(?<!\d)(18|19|20|21)\d\d(?!\d)"#, #"(?<![\dA-Za-z])'?\d0s\b"#, #"lat(a|ach)\s+\d0"#]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static let kindWords: [LibraryFilter.Category: [String]] = [
        .movies: ["movie", "movies", "film", "films", "filmy", "film"],
        .series: ["series", "show", "shows", "tv", "seriale", "serial"],
        .books: ["book", "books", "ebook", "ebooks", "książki", "ksiazki", "książka"],
        .audiobooks: ["audiobook", "audiobooks", "audiobooki"],
        .music: ["music", "album", "albums", "muzyka"],
        .software: ["software", "app", "apps", "program", "programs"],
        .adult: ["adult", "xxx"],
        .other: ["other", "others", "inne"],
    ]

    static let statusWords: [LibraryFilter.Status: [String]] = [
        .ready: ["ready", "finished", "done", "gotowe"],
        .active: ["downloading", "queued", "pending", "in progress", "pobierane"],
        .failed: ["failed", "broken", "error", "errors", "nieudane"],
    ]

    static let serviceWords: [BackendID: [String]] = [
        .realDebrid: ["rd", "real debrid"], .torBox: ["tb", "torbox"], .offcloud: ["oc"], .debridLink: ["dl", "debrid link"],
        .premiumize: ["pm"], .allDebrid: ["ad", "all debrid"], .nzbdav: ["usenet", "infinidysk"], .iCloudDrive: ["icloud"],
        .calibre: ["calibre"],
    ]

    static let genreWords = [
        "horror", "horrors", "comedy", "comedies", "drama", "dramas", "thriller", "thrillers", "action", "romance", "romantic",
        "sci-fi", "science fiction", "fantasy", "documentary", "documentaries", "animated", "animation", "anime", "crime",
        "western", "westerns", "war", "musical", "kids", "family", "mystery", "biography", "history", "historical",
    ]
}
