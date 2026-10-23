import Foundation

/// Search and metadata from TMDB with the user's own key, used before the metadata addons when configured.
///
/// IDs: search results are `tmdb:<id>`; `detail(of:)` swaps in the IMDb ID (`external_ids`) when TMDB has
/// one, so episodes become `tt…:season:episode` like Cinemeta's and every stream addon and indexer accepts them.
/// `tt…` IDs (matches made through an addon) are looked up with `/find`.
///
/// Auth: a v4 read access token (a JWT) goes in `Authorization: Bearer`; a v3 API key can only travel in the
/// query (`api_key=`), so request URLs are never logged.
public struct TMDBMetadata: Sendable {
    public static let baseURL = URL(string: "https://api.themoviedb.org/3")!
    static let imageBase = "https://image.tmdb.org/t/p/"
    /// Titles match release names (which are English or original) far better than translations.
    public static let language = "en-US"
    /// `append_to_response` takes at most 20 items.
    static let seasonsPerRequest = 20

    private let key: String
    private let transport: any HTTPTransport

    public init(key: String, transport: any HTTPTransport = URLSession.shared) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    /// v4 read access tokens are JWTs; v3 keys are 32 hex characters.
    var usesBearer: Bool { key.hasPrefix("eyJ") && key.contains(".") }

    /// Checks the key (`/authentication` answers 401 to a bad one).
    public func validate() async throws {
        _ = try await get(TMDBStatus.self, "authentication")
    }

    // MARK: - Search

    /// Movies and series, in TMDB's relevance order.
    public func search(_ query: String) async throws -> [MediaSummary] {
        let page = try await get(TMDBPage.self, "search/multi", ["query": query, "include_adult": "false"])
        return page.results.compactMap { $0.summary(as: nil) }
    }

    public func search(_ query: String, type: MediaType) async throws -> [MediaSummary] {
        let page = try await get(TMDBPage.self, "search/\(type.tmdbPath)", ["query": query, "include_adult": "false"])
        return page.results.compactMap { $0.summary(as: type) }
    }

    // MARK: - Detail

    /// Full metadata for a `tmdb:<id>` or `tt…` ID; seasons and episodes for series unless `includeEpisodes`
    /// is false (`AddonSet` takes episodes from the metadata addon, whose numbering the stream addons share).
    public func detail(of item: MediaSummary, includeEpisodes: Bool = true) async throws -> MediaDetail {
        let tmdbID = try await tmdbID(of: item)
        let path = "\(item.type.tmdbPath)/\(tmdbID)"
        let show = try await get(TMDBTitle.self, path, ["append_to_response": "external_ids"])
        let imdbID = (show.imdbID ?? show.externalIDs?.imdbID).flatMap { $0.hasPrefix("tt") ? $0 : nil }
        // Stream addons and indexers want IMDb IDs; without one, AIOStreams-style `tmdb:` IDs are the fallback.
        let streamID = imdbID ?? "tmdb:\(tmdbID)"
        guard var summary = show.result.summary(as: item.type) else { throw BackendError.invalidResponse }
        summary = MediaSummary(
            id: streamID,
            type: summary.type,
            name: summary.name,
            releaseInfo: summary.releaseInfo,
            poster: summary.poster ?? item.poster,
            background: summary.background ?? item.background,
            description: summary.description ?? item.description,
            imdbRating: item.imdbRating
        )
        let minutes = show.runtime ?? show.episodeRunTime?.first
        let seasonInfo = Dictionary(
            (show.seasons ?? []).map { ($0.seasonNumber, $0.info) },
            uniquingKeysWith: { first, _ in first }
        )
        var episodes: [Episode] = []
        if item.type == .series, includeEpisodes {
            let numbers = (show.seasons ?? []).filter { $0.episodeCount > 0 }.map(\.seasonNumber)
            episodes = try await self.episodes(path: path, seasons: numbers, streamID: streamID)
        }
        return MediaDetail(
            summary: summary,
            genres: (show.genres ?? []).map(\.name),
            runtime: minutes.flatMap { $0 > 0 ? "\($0) min" : nil },
            episodes: episodes,
            seasonInfo: seasonInfo
        )
    }

    // MARK: - Release dates

    /// A movie's theatrical, digital and physical dates (`movie/{id}/release_dates`): the US when it has them,
    /// else the earliest of each kind anywhere.
    public func releaseDates(of movie: MediaSummary, now: Date = .now) async throws -> MovieRelease {
        let id = try await tmdbID(of: movie)
        let response = try await get(TMDBReleaseDates.self, "movie/\(id)/release_dates")
        func earliest(_ types: Set<Int>) -> Date? {
            let dates = { (countries: [TMDBReleaseDates.Country]) in
                countries.flatMap(\.releaseDates).filter { types.contains($0.type) }.compactMap { Self.parseTimestamp($0.releaseDate) }
            }
            return dates(response.results.filter { $0.country == "US" }).min() ?? dates(response.results).min()
        }
        // TMDB types: 1 premiere, 2 limited theatrical, 3 theatrical, 4 digital, 5 physical, 6 TV.
        return MovieRelease(theatrical: earliest([2, 3]), digital: earliest([4]), physical: earliest([5]), fetchedAt: now)
    }

    /// `2024-03-01T00:00:00.000Z`.
    static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text) ?? parseDay(String(text.prefix(10)))
    }

    // MARK: - Discover

    /// TMDB's keyword for a word ("memory" → its ID), the first match; nil when TMDB has none.
    public func keywordID(_ word: String) async throws -> Int? {
        try await get(TMDBKeywords.self, "search/keyword", ["query": word]).results.first?.id
    }

    /// Titles tagged with a keyword, most popular first, narrowed by genres and years; titles with few votes
    /// (unreleased, obscure) are left out.
    public func discover(_ type: MediaType, keyword: Int, genres: [Int] = [], years: ClosedRange<Int>? = nil) async throws -> [MediaSummary] {
        var parameters = ["with_keywords": String(keyword), "sort_by": "popularity.desc", "vote_count.gte": "30", "include_adult": "false"]
        if !genres.isEmpty { parameters["with_genres"] = genres.map(String.init).joined(separator: "|") }
        if let years {
            let field = type == .movie ? "primary_release_date" : "first_air_date"
            parameters["\(field).gte"] = "\(years.lowerBound)-01-01"
            parameters["\(field).lte"] = "\(years.upperBound)-12-31"
        }
        return try await get(TMDBPage.self, "discover/\(type.tmdbPath)", parameters).results.compactMap { $0.summary(as: type) }
    }

    /// TMDB's genre IDs by name; movies and series have their own lists ("Sci-Fi & Fantasy" is one series genre).
    public static func genreIDs(_ names: [String], for type: MediaType) -> [Int] {
        let table: [String: Int] = type == .movie
            ? ["action": 28, "adventure": 12, "animation": 16, "comedy": 35, "crime": 80, "documentary": 99, "drama": 18,
               "family": 10751, "fantasy": 14, "history": 36, "horror": 27, "music": 10402, "mystery": 9648,
               "romance": 10749, "science fiction": 878, "thriller": 53, "war": 10752, "western": 37]
            : ["action": 10759, "adventure": 10759, "animation": 16, "comedy": 35, "crime": 80, "documentary": 99,
               "drama": 18, "family": 10751, "kids": 10762, "mystery": 9648, "science fiction": 10765, "fantasy": 10765,
               "war": 10768, "western": 37]
        return Array(Set(names.compactMap { table[$0.lowercased()] })).sorted()
    }

    /// The movie or series with this IMDb ID (`/find`), nil when TMDB does not know it.
    public func find(imdbID: String) async throws -> MediaSummary? {
        let found = try await get(TMDBFind.self, "find/\(imdbID)", ["external_source": "imdb_id"])
        if let movie = found.movieResults.first?.summary(as: .movie) { return movie }
        return found.tvResults.first?.summary(as: .series)
    }

    private func tmdbID(of item: MediaSummary) async throws -> Int {
        if item.id.hasPrefix("tmdb:"), let id = Int(item.id.dropFirst(5).split(separator: ":").first ?? "") {
            return id
        }
        guard item.id.hasPrefix("tt") else { throw BackendError.notFound }
        let imdbID = String(item.id.split(separator: ":").first ?? "")
        let found = try await get(TMDBFind.self, "find/\(imdbID)", ["external_source": "imdb_id"])
        let results = item.type == .movie ? found.movieResults : found.tvResults
        guard let id = results.first?.id else { throw BackendError.notFound }
        return id
    }

    /// Every season's episodes, 20 seasons per request (`append_to_response=season/1,season/2…`).
    private func episodes(path: String, seasons: [Int], streamID: String) async throws -> [Episode] {
        var episodes: [Episode] = []
        for start in stride(from: 0, to: seasons.count, by: Self.seasonsPerRequest) {
            let chunk = seasons[start..<min(start + Self.seasonsPerRequest, seasons.count)]
            let append = chunk.map { "season/\($0)" }.joined(separator: ",")
            let response = try await get(TMDBSeasons.self, path, ["append_to_response": append])
            for season in chunk {
                for episode in response.seasons[season]?.episodes ?? [] {
                    episodes.append(Episode(
                        id: "\(streamID):\(season):\(episode.episodeNumber)",
                        season: season,
                        number: episode.episodeNumber,
                        title: episode.name.flatMap { $0.isEmpty ? nil : $0 },
                        overview: episode.overview.flatMap { $0.isEmpty ? nil : $0 },
                        thumbnail: Self.image(episode.stillPath, size: "w300"),
                        released: episode.airDate.flatMap(Self.parseDay)
                    ))
                }
            }
        }
        return episodes
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ parameters: [String: String] = [:]) async throws -> T {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "language", value: Self.language)]
        items += parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !usesBearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if usesBearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.send(request)
        if let error = response.backendError {
            // TMDB explains itself in `status_message` (e.g. "Invalid API key: You must be granted a valid key.").
            if error == .unauthorized { throw BackendError.api(message: "TMDB refused the key. Use the API key or the API read access token from TMDB's settings.") }
            throw error
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }

    static func image(_ path: String?, size: String) -> URL? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(string: imageBase + size + path)
    }

    /// TMDB dates are plain days (`2024-03-01`); read them as UTC midnight.
    static func parseDay(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

extension MediaType {
    var tmdbPath: String { self == .movie ? "movie" : "tv" }
}

// MARK: - Wire types

private struct TMDBStatus: Decodable {}

private struct TMDBKeywords: Decodable {
    struct Keyword: Decodable { let id: Int }
    let results: [Keyword]
}

private struct TMDBReleaseDates: Decodable {
    struct Country: Decodable {
        let country: String
        let releaseDates: [Release]

        enum CodingKeys: String, CodingKey {
            case country = "iso_3166_1"
            case releaseDates = "release_dates"
        }
    }

    struct Release: Decodable {
        let type: Int
        let releaseDate: String

        enum CodingKeys: String, CodingKey {
            case type
            case releaseDate = "release_date"
        }
    }

    let results: [Country]
}

private struct TMDBPage: Decodable {
    let results: [TMDBResult]

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One odd entry must not sink the page.
        results = (try c.decode([Lenient<TMDBResult>].self, forKey: .results)).compactMap(\.value)
    }

    enum CodingKeys: String, CodingKey { case results }
}

private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

/// A search hit, or the common fields of a movie/series detail.
private struct TMDBResult: Decodable {
    let id: Int
    let mediaType: String?
    let title: String?
    let name: String?
    let releaseDate: String?
    let firstAirDate: String?
    let posterPath: String?
    let backdropPath: String?
    let overview: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case mediaType = "media_type"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
    }

    /// `type` nil: take it from `media_type` (multi search), skipping people.
    func summary(as type: MediaType?) -> MediaSummary? {
        let resolved: MediaType? = type ?? {
            switch mediaType {
            case "movie": .movie
            case "tv": .series
            default: nil
            }
        }()
        guard let resolved, let title = title ?? name, !title.isEmpty else { return nil }
        let date = releaseDate ?? firstAirDate
        let year = date.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
        return MediaSummary(
            id: "tmdb:\(id)",
            type: resolved,
            name: title,
            releaseInfo: year,
            poster: TMDBMetadata.image(posterPath, size: "w342"),
            background: TMDBMetadata.image(backdropPath, size: "w1280"),
            description: overview.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

private struct TMDBTitle: Decodable {
    let result: TMDBResult
    let imdbID: String?
    let externalIDs: ExternalIDs?
    let genres: [Genre]?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let seasons: [Season]?

    struct ExternalIDs: Decodable {
        let imdbID: String?
        enum CodingKeys: String, CodingKey { case imdbID = "imdb_id" }
    }

    struct Genre: Decodable { let name: String }

    struct Season: Decodable {
        let seasonNumber: Int
        let episodeCount: Int
        let name: String?
        let overview: String?
        let posterPath: String?
        let airDate: String?
        enum CodingKeys: String, CodingKey {
            case seasonNumber = "season_number"
            case episodeCount = "episode_count"
            case name, overview
            case posterPath = "poster_path"
            case airDate = "air_date"
        }

        var info: SeasonInfo {
            SeasonInfo(
                name: name.flatMap { $0.isEmpty ? nil : $0 },
                overview: overview.flatMap { $0.isEmpty ? nil : $0 },
                poster: TMDBMetadata.image(posterPath, size: "w342"),
                episodeCount: episodeCount,
                airDate: airDate.flatMap(TMDBMetadata.parseDay)
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case genres, runtime, seasons
        case imdbID = "imdb_id"
        case externalIDs = "external_ids"
        case episodeRunTime = "episode_run_time"
    }

    init(from decoder: any Decoder) throws {
        result = try TMDBResult(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imdbID = try? c.decodeIfPresent(String.self, forKey: .imdbID)
        externalIDs = try? c.decodeIfPresent(ExternalIDs.self, forKey: .externalIDs)
        genres = try? c.decodeIfPresent([Genre].self, forKey: .genres)
        runtime = try? c.decodeIfPresent(Int.self, forKey: .runtime)
        episodeRunTime = try? c.decodeIfPresent([Int].self, forKey: .episodeRunTime)
        seasons = try? c.decodeIfPresent([Season].self, forKey: .seasons)
    }
}

/// `/tv/{id}?append_to_response=season/1,…`: each season under its own `season/N` key.
private struct TMDBSeasons: Decodable {
    let seasons: [Int: SeasonDetail]

    struct SeasonDetail: Decodable {
        let episodes: [EpisodeDetail]
    }

    struct EpisodeDetail: Decodable {
        let episodeNumber: Int
        let name: String?
        let overview: String?
        let stillPath: String?
        let airDate: String?

        enum CodingKeys: String, CodingKey {
            case name, overview
            case episodeNumber = "episode_number"
            case stillPath = "still_path"
            case airDate = "air_date"
        }
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var seasons: [Int: SeasonDetail] = [:]
        for key in c.allKeys where key.stringValue.hasPrefix("season/") {
            if let number = Int(key.stringValue.dropFirst("season/".count)),
               let detail = try? c.decode(SeasonDetail.self, forKey: key) {
                seasons[number] = detail
            }
        }
        self.seasons = seasons
    }
}

private struct TMDBFind: Decodable {
    let movieResults: [TMDBResult]
    let tvResults: [TMDBResult]

    enum CodingKeys: String, CodingKey {
        case movieResults = "movie_results"
        case tvResults = "tv_results"
    }
}
