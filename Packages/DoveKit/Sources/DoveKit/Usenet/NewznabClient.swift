import Foundation

/// Newznab's top-level categories Dove searches outside movies and series (Search › Other).
public enum NewznabCategory: String, CaseIterable, Sendable, Hashable, Codable {
    /// No category: whatever the indexer finds for the words.
    case all
    /// Consoles (1000) and PC games (4050).
    case games
    case software
    case music
    case books
    /// Audio › Audiobook (3030), apart from music.
    case audiobooks
    /// Hidden unless the user shows adult content.
    case adult

    /// `cat=` values. Indexers match their subcategories (4000 covers 4010 Windows, 4050 PC games…).
    var ids: [Int] {
        switch self {
        case .all: []
        case .games: [1000, 4050]
        case .software: [4000]
        case .music: [3000]
        case .books: [7000]
        case .audiobooks: [3030]
        case .adult: [6000]
        }
    }

    public var displayName: String {
        switch self {
        case .all: "All"
        case .games: "Games"
        case .software: "Software"
        case .music: "Music"
        case .books: "Books"
        case .audiobooks: "Audiobooks"
        case .adult: "Adult"
        }
    }
}

/// What to look for: a movie, one episode, a whole season (packs and its episodes), or free text in a category.
public enum NewznabQuery: Sendable, Hashable {
    case movie(imdbID: String, title: String?)
    case episode(imdbID: String, season: Int, episode: Int, title: String?)
    case season(imdbID: String, season: Int, title: String?)
    /// Search › Other: words, no IMDb ID, results from any category the user picked.
    case text(String, category: NewznabCategory)
    /// One book or audiobook picked from the metadata services: `t=book` with `title=`/`author=` where the
    /// indexer has it (caps `book-search`), else a plain search for "author title".
    case book(title: String, author: String?, category: NewznabCategory)
    /// One album picked from the metadata services: `t=music` with `album=`/`artist=` where the indexer has it
    /// (caps `audio-search`), else a plain search for "artist album" in Music.
    case album(title: String, artist: String?)

    /// From a Stremio stream ID (`tt123` or `tt123:2:5`). Nil for IDs indexers cannot search (kitsu…).
    public init?(type: MediaType, id: String, title: String?, wholeSeason: Bool) {
        let parts = id.split(separator: ":").map(String.init)
        guard let imdb = parts.first, imdb.hasPrefix("tt"), imdb.count > 2 else { return nil }
        switch type {
        case .movie:
            self = .movie(imdbID: imdb, title: title)
        case .series:
            guard parts.count >= 3, let season = Int(parts[1]), let episode = Int(parts[2]) else { return nil }
            self = wholeSeason
                ? .season(imdbID: imdb, season: season, title: title)
                : .episode(imdbID: imdb, season: season, episode: episode, title: title)
        }
    }

    /// `t=` for an indexer that takes these parameters: a book search falls back to `search` without `title`.
    func function(supported: Set<String>) -> String {
        switch self {
        case .movie: "movie"
        case .episode, .season: "tvsearch"
        case .text: "search"
        case .book: supported.contains("title") ? "book" : "search"
        case .album: supported.contains("album") ? "music" : "search"
        }
    }

    var imdbID: String? {
        switch self {
        case .movie(let id, _), .episode(let id, _, _, _), .season(let id, _, _): id
        case .text, .book, .album: nil
        }
    }

    var title: String? {
        switch self {
        case .movie(_, let title), .episode(_, _, _, let title), .season(_, _, let title): title
        case .text(let words, _): words
        case .book(let title, let author, _), .album(let title, let author): [author, title].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// Book and album searches use caps Dove did not read at first: caps saved before are asked again.
    func needsNewerCaps(_ caps: NewznabCaps) -> Bool {
        switch self {
        case .book: caps.bookParams == nil
        case .album: caps.musicParams == nil
        default: false
        }
    }

    /// Top-level categories a result must belong to. Movie and series searches ask for Movies (2000) or
    /// TV (5000) only, so a title that matches software or music never turns up among a film's sources.
    var categories: [Int] {
        switch self {
        case .movie: [2000]
        case .episode, .season: [5000]
        case .text(_, let category), .book(_, _, let category): category.ids
        case .album: NewznabCategory.music.ids
        }
    }

    /// Search parameters for an indexer: the IMDb ID when it takes one, the title otherwise.
    func parameters(supported: Set<String>) -> [URLQueryItem]? {
        var items: [URLQueryItem] = []
        if case .book(let title, let author, _) = self, supported.contains("title") {
            items.append(URLQueryItem(name: "title", value: title))
            if let author, supported.contains("author") { items.append(URLQueryItem(name: "author", value: author)) }
        } else if case .album(let title, let artist) = self, supported.contains("album") {
            items.append(URLQueryItem(name: "album", value: title))
            if let artist, supported.contains("artist") { items.append(URLQueryItem(name: "artist", value: artist)) }
        } else if let imdbID, supported.contains("imdbid") {
            items.append(URLQueryItem(name: "imdbid", value: String(imdbID.dropFirst(2))))
        } else if let title, !title.isEmpty {
            items.append(URLQueryItem(name: "q", value: title))
        } else {
            return nil
        }
        if !categories.isEmpty {
            items.append(URLQueryItem(name: "cat", value: categories.map(String.init).joined(separator: ",")))
        }
        switch self {
        case .movie, .text, .book, .album:
            break
        case .episode(_, let season, let episode, _):
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "ep", value: String(episode)))
        case .season(_, let season, _):
            items.append(URLQueryItem(name: "season", value: String(season)))
        }
        return items
    }
}

/// What an indexer says it can search with (`t=caps`).
public struct NewznabCaps: Codable, Sendable, Hashable {
    public var movieParams: Set<String>
    public var tvParams: Set<String>
    public var maxLimit: Int?
    /// `book-search` parameters (`q,title,author`); empty when the indexer has none, nil in caps saved before
    /// Dove read them (asked again on the first book search).
    public var bookParams: Set<String>?
    /// `audio-search` parameters (`q,artist,album`), the same way.
    public var musicParams: Set<String>?

    public init(
        movieParams: Set<String>, tvParams: Set<String>, maxLimit: Int? = nil, bookParams: Set<String>? = nil, musicParams: Set<String>? = nil
    ) {
        self.movieParams = movieParams
        self.tvParams = tvParams
        self.maxLimit = maxLimit
        self.bookParams = bookParams
        self.musicParams = musicParams
    }

    func params(for query: NewznabQuery) -> Set<String> {
        switch query {
        case .movie: movieParams
        case .episode, .season: tvParams
        // Every Newznab indexer has the plain `search` function, with `q`.
        case .text: ["q"]
        case .book: (bookParams ?? []).union(["q"])
        case .album: (musicParams ?? []).union(["q"])
        }
    }
}

public enum NewznabError: Error, LocalizedError, Equatable {
    /// Codes 100–104: wrong or suspended key, missing privileges.
    case unauthorized(String)
    /// The daily API (or download) limit is used up.
    case limitReached(String)
    case api(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let message): "The indexer refused the API key: \(message)"
        case .limitReached(let message): "Daily limit reached: \(message)"
        case .api(_, let message): message
        }
    }
}

/// One indexer's Newznab API. The API key travels in the query (the protocol has no other way), so request
/// URLs are never logged (`HTTPTransport` marks paths private; queries are not logged at all).
public struct NewznabClient: Sendable {
    public let indexer: NewznabIndexer
    private let transport: any HTTPTransport

    public init(indexer: NewznabIndexer, transport: any HTTPTransport = URLSession.shared) {
        self.indexer = indexer
        self.transport = transport
    }

    public func caps() async throws -> NewznabCaps {
        let document = try await fetch([URLQueryItem(name: "t", value: "caps")])
        guard let caps = document.caps else { throw BackendError.invalidResponse }
        return caps
    }

    /// Nil when the indexer cannot run this search (no IMDb support and no title).
    public func search(_ query: NewznabQuery, caps: NewznabCaps) async throws -> [StreamCandidate]? {
        let supported = caps.params(for: query)
        guard let parameters = query.parameters(supported: supported) else { return nil }
        let limit = min(caps.maxLimit ?? 100, 100)
        let document = try await fetch(
            [URLQueryItem(name: "t", value: query.function(supported: supported))] + parameters
                + [URLQueryItem(name: "extended", value: "1"), URLQueryItem(name: "limit", value: String(limit))]
        )
        let wanted = Set(query.categories)
        return document.items.enumerated().compactMap { index, item in
            // Some indexers ignore `cat`: drop what is plainly from another category. A parent (3000) takes its
            // subcategories; a subcategory (3030) only itself.
            if !wanted.isEmpty, let category = item.category,
               !wanted.contains(where: { $0 % 1000 == 0 ? category / 1000 * 1000 == $0 : category == $0 }) { return nil }
            return item.candidate(id: "newznab:\(indexer.id):\(item.guid ?? String(index))", indexer: indexer)
        }
    }

    private func fetch(_ items: [URLQueryItem]) async throws -> NewznabDocument {
        var components = URLComponents(url: indexer.url, resolvingAgainstBaseURL: false)!
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + indexer.apiPath
        components.queryItems = items + [URLQueryItem(name: "apikey", value: indexer.apiKey)]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        let (data, response) = try await transport.send(request)
        // An error document outranks the status code: indexers often send one with a 4xx.
        let document = NewznabParser.parse(data)
        if let error = document.error { throw error }
        if response.statusCode == 429 { throw NewznabError.limitReached("too many requests") }
        if let error = response.backendError { throw error }
        guard document.isNewznab else { throw BackendError.invalidResponse }
        return document
    }
}

struct NewznabItem {
    var title: String?
    var guid: String?
    var link: String?
    var enclosureURL: String?
    var enclosureLength: Int64?
    var attrs: [String: String] = [:]
    /// Every `category` attribute, parent first (`3000`, `3010`).
    var categories: [Int] = []
    /// The tracker behind an aggregate feed: Jackett's `jackettindexer`, Prowlarr's `prowlarrindexer`.
    var tracker: String?
    /// Jackett's `type` element or Prowlarr's `type` attribute: `public`, `semi-private`, `private`.
    var trackerType: String?
    var pubDate: String?

    /// Semi-private trackers count as private: they also want seeding back.
    var isPrivate: Bool? {
        guard let type = trackerType?.lowercased(), !type.isEmpty else { return nil }
        return type.contains("private")
    }

    var published: Date? {
        (pubDate ?? attrs["usenetdate"]).flatMap(Self.parseDate)
    }

    /// RSS dates (`Tue, 14 Oct 2026 10:00:00 +0000`), with or without the weekday.
    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return nil
    }

    /// The most specific standard category the indexer gave. Jackett adds its trackers' own categories
    /// (100000 and up); they say nothing Dove understands. Audiobook (3030) wins over anything else: Jackett and
    /// Prowlarr often tag audiobooks Books (7000) too, which made them pass a Books search.
    var category: Int? {
        let standard = categories.filter { $0 < 100_000 }
        return standard.contains(3030) ? 3030 : standard.max()
    }

    func candidate(id: String, indexer: NewznabIndexer) -> StreamCandidate? {
        guard let title, !title.isEmpty else { return nil }
        let size = attrs["size"].flatMap(Int64.init) ?? enclosureLength
        let links = [enclosureURL, link].compactMap { $0.flatMap(URL.init(string:)) }
        switch indexer.kind {
        case .newznab:
            guard let nzb = links.first else { return nil }
            return StreamCandidate(
                id: id, kind: .usenet, title: title, label: indexer.name, size: size, nzbURL: nzb, category: category,
                provider: indexer.name, tracker: tracker, published: published
            )
        case .torznab:
            // The info hash shows cache status; adds fetch the .torrent when there is one (private trackers need
            // the file), else use the magnet.
            let magnet = ([attrs["magneturl"]] + links.map(\.absoluteString)).compactMap { $0 }.first { $0.hasPrefix("magnet:") }
            let hash = attrs["infohash"].flatMap(Self.validHash) ?? magnet.flatMap(Self.hash(inMagnet:))
            let torrent = links.first { $0.scheme == "http" || $0.scheme == "https" }
            guard hash != nil || torrent != nil else { return nil }
            return StreamCandidate(
                id: id,
                kind: .p2p,
                title: title,
                label: indexer.name,
                size: size,
                infoHash: hash,
                category: category,
                torrentURL: torrent,
                seeders: attrs["seeders"].flatMap(Int.init),
                provider: indexer.name,
                tracker: tracker,
                isPrivate: isPrivate,
                published: published
            )
        }
    }

    /// 40 hex characters, lowercased.
    static func validHash(_ text: String) -> String? {
        let hash = text.trimmingCharacters(in: .whitespaces).lowercased()
        return hash.count == 40 && hash.allSatisfy(\.isHexDigit) ? hash : nil
    }

    static func hash(inMagnet magnet: String) -> String? {
        let topics = URLComponents(string: magnet)?.queryItems?.filter { $0.name.lowercased() == "xt" } ?? []
        return topics.lazy.compactMap { $0.value }
            .filter { $0.lowercased().hasPrefix("urn:btih:") }
            .compactMap { validHash(String($0.dropFirst(9))) }
            .first
    }
}

struct NewznabDocument {
    var items: [NewznabItem] = []
    var caps: NewznabCaps?
    var error: NewznabError?
    /// Saw an `rss`, `caps` or `error` root: anything else (an HTML login page) is not an answer.
    var isNewznab = false
}

/// Reads Newznab RSS (`item`, `enclosure`, `newznab:attr`), `caps` and `error` documents.
final class NewznabParser: NSObject, XMLParserDelegate {
    private var document = NewznabDocument()
    private var item: NewznabItem?
    private var text = ""
    private var movieParams = Set<String>()
    private var tvParams = Set<String>()
    private var bookParams = Set<String>()
    private var musicParams = Set<String>()
    private var inCaps = false

    static func parse(_ data: Data) -> NewznabDocument {
        let delegate = NewznabParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.document
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "rss":
            document.isNewznab = true
        case "caps":
            document.isNewznab = true
            inCaps = true
        case "error":
            document.isNewznab = true
            let code = Int(attributes["code"] ?? "") ?? 0
            let message = attributes["description"] ?? "Indexer error \(code)"
            document.error = switch code {
            case 100...104: .unauthorized(message)
            case 429, 500, 501: .limitReached(message)
            default: message.localizedCaseInsensitiveContains("limit") ? .limitReached(message) : .api(code: code, message: message)
            }
        case "item":
            item = NewznabItem()
        case "prowlarrindexer":
            item?.trackerType = attributes["type"]
        case "enclosure":
            item?.enclosureURL = attributes["url"]
            item?.enclosureLength = attributes["length"].flatMap(Int64.init)
        case "newznab:attr", "torznab:attr", "attr":
            guard let key = attributes["name"], let value = attributes["value"] else { break }
            if key == "category" {
                if let id = Int(value) { item?.categories.append(id) }
            } else {
                item?.attrs[key] = value
            }
        case "movie-search", "tv-search", "book-search", "audio-search":
            guard inCaps, attributes["available"]?.lowercased() != "no" else { break }
            let params = Set((attributes["supportedParams"] ?? "q").lowercased().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            })
            switch name {
            case "movie-search": movieParams = params
            case "tv-search": tvParams = params
            case "audio-search": musicParams = params
            default: bookParams = params
            }
        case "limits":
            if inCaps { document.caps = NewznabCaps(movieParams: [], tvParams: [], maxLimit: attributes["max"].flatMap(Int.init)) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": item?.title = value
        case "guid": item?.guid = value
        case "link": item?.link = value
        case "jackettindexer", "prowlarrindexer": item?.tracker = value.isEmpty ? nil : value
        case "type": if item != nil, !value.isEmpty { item?.trackerType = value }
        case "pubDate": item?.pubDate = value
        case "item":
            if let item { document.items.append(item) }
            item = nil
        case "caps":
            var caps = document.caps ?? NewznabCaps(movieParams: [], tvParams: [], maxLimit: nil)
            caps.movieParams = movieParams
            caps.tvParams = tvParams
            caps.bookParams = bookParams
            caps.musicParams = musicParams
            document.caps = caps
            inCaps = false
        default:
            break
        }
        text = ""
    }
}
