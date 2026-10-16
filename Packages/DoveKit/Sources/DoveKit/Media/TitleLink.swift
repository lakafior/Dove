import Foundation

/// A link to a movie's or series' page elsewhere (IMDb, TMDB, Apple TV, Letterboxd, Trakt, Rotten Tomatoes,
/// JustWatch), shared to Dove or pasted into its search field: Dove opens that title instead of treating the link as
/// a hoster link (no debrid unlocks these sites).
public enum TitleLink: Hashable, Sendable {
    /// `tt…`: certain.
    case imdb(String)
    /// TMDB's own ID: certain, needs a TMDB key.
    case tmdb(id: Int, type: MediaType)
    /// Only a name (from the page's address), found by searching; the year when the address has one.
    case named(title: String, year: Int?, type: MediaType?)

    public init?(url: URL) {
        guard let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        func after(_ marker: String) -> String? {
            parts.firstIndex(of: marker).flatMap { parts.indices.contains($0 + 1) ? parts[$0 + 1] : nil }
        }

        if host.hasSuffix("imdb.com"), let id = after("title"), id.hasPrefix("tt"), id.dropFirst(2).allSatisfy(\.isNumber) {
            self = .imdb(id)
        } else if host.hasSuffix("themoviedb.org") {
            for (marker, type) in [("movie", MediaType.movie), ("tv", .series)] {
                if let slug = after(marker), let id = Int(slug.prefix { $0.isNumber }) {
                    self = .tmdb(id: id, type: type)
                    return
                }
            }
            return nil
        } else if host == "tv.apple.com" {
            for (marker, type) in [("movie", MediaType.movie), ("show", .series)] {
                if let slug = after(marker) {
                    self = Self.named(slug, type: type)
                    return
                }
            }
            return nil
        } else if host.hasSuffix("letterboxd.com"), let slug = after("film") {
            self = Self.named(slug, type: .movie)
        } else if host.hasSuffix("trakt.tv") {
            for (marker, type) in [("movies", MediaType.movie), ("shows", .series)] {
                if let slug = after(marker) {
                    self = Self.named(slug, type: type)
                    return
                }
            }
            return nil
        } else if host.hasSuffix("rottentomatoes.com") {
            for (marker, type) in [("m", MediaType.movie), ("tv", .series)] {
                if let slug = after(marker) {
                    self = Self.named(slug, type: type)
                    return
                }
            }
            return nil
        } else if host.hasSuffix("justwatch.com"), parts.count >= 3 {
            // `/pl/film/<slug>`, `/us/movie/<slug>`, `/us/tv-show/<slug>`, `/pl/serial/<slug>`.
            let kind = parts[1].lowercased()
            let type: MediaType? = ["movie", "film", "filme", "pelicula"].contains(kind) ? .movie
                : ["tv-show", "tv-series", "serial", "serie", "series"].contains(kind) ? .series : nil
            guard type != nil else { return nil }
            self = Self.named(parts[2], type: type)
        } else {
            return nil
        }
    }

    /// The first title link in text (a share sheet's text, the search field).
    public static func first(in text: String) -> TitleLink? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        for match in detector?.matches(in: text, range: range) ?? [] {
            if let url = match.url, let link = TitleLink(url: url) { return link }
        }
        return nil
    }

    /// `blade-runner-2049-2017` → "blade runner 2049", 2017. A trailing year is only taken when it leaves a title.
    static func named(_ slug: String, type: MediaType?) -> TitleLink {
        var words = slug.removingPercentEncoding?.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "+" }).map(String.init) ?? []
        var year: Int?
        if words.count > 1, let last = words.last, last.count == 4, let value = Int(last), (1888...2100).contains(value) {
            year = value
            words.removeLast()
        }
        return .named(title: words.joined(separator: " "), year: year, type: type)
    }

    /// The text to search for when nothing resolves it.
    public var searchText: String {
        switch self {
        case .imdb(let id): id
        case .tmdb(let id, _): "tmdb:\(id)"
        case .named(let title, let year, _): year.map { "\(title) \($0)" } ?? title
        }
    }

    // MARK: - Deep link

    /// `dove://media?imdb=tt…`, `dove://media?tmdb=123&type=movie`, `dove://media?q=…&year=…&type=…`: what the share
    /// extension opens the app with.
    public var deepLink: URL {
        var components = URLComponents()
        components.scheme = "dove"
        components.host = "media"
        switch self {
        case .imdb(let id):
            components.queryItems = [URLQueryItem(name: "imdb", value: id)]
        case .tmdb(let id, let type):
            components.queryItems = [URLQueryItem(name: "tmdb", value: String(id)), URLQueryItem(name: "type", value: type.rawValue)]
        case .named(let title, let year, let type):
            components.queryItems = [URLQueryItem(name: "q", value: title)]
                + (year.map { [URLQueryItem(name: "year", value: String($0))] } ?? [])
                + (type.map { [URLQueryItem(name: "type", value: $0.rawValue)] } ?? [])
        }
        return components.url!
    }

    public init?(deepLink url: URL) {
        guard url.scheme == "dove", url.host() == "media",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let type = value("type").flatMap(MediaType.init(rawValue:))
        if let id = value("imdb") {
            self = .imdb(id)
        } else if let id = value("tmdb").flatMap(Int.init), let type {
            self = .tmdb(id: id, type: type)
        } else if let title = value("q"), !title.isEmpty {
            self = .named(title: title, year: value("year").flatMap(Int.init), type: type)
        } else {
            return nil
        }
    }
}

extension AddonSet {
    /// The title a link points to: through TMDB when there is a key, else the metadata addons (IMDb IDs) or the search
    /// addon (names). Nil when nothing fitting is found.
    public func resolve(_ link: TitleLink) async -> MediaSummary? {
        switch link {
        case .imdb(let id):
            if let tmdb, let found = try? await tmdb.find(imdbID: id) { return found }
            // The type is not in the link: the addon that knows it as one or the other says which.
            for type in [MediaType.movie, .series] {
                for addon in addons where addon.manifest.accepts("meta", type: type, id: id) {
                    if let detail = try? await addon.meta(type: type, id: id) { return detail.summary }
                }
            }
            return nil
        case .tmdb(let id, let type):
            guard let tmdb else { return nil }
            return try? await tmdb.detail(of: MediaSummary(id: "tmdb:\(id)", type: type, name: ""), includeEpisodes: false).summary
        case .named(let title, let year, let type):
            let results: [MediaSummary]
            if let type { results = (try? await search(title, type: type)) ?? [] } else { results = (try? await search(title)) ?? [] }
            return LibraryMatcher.best(results, for: MediaGuess(title: title, year: year, type: type ?? .movie))
        }
    }
}
