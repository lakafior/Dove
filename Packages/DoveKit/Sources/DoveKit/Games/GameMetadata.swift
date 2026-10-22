import Foundation

/// A game as a metadata service describes it: real title, year, platforms, cover.
public struct GameSummary: Identifiable, Sendable, Hashable, Codable {
    /// `igdb:<id>` or `wd:<Q-id>` (Wikidata).
    public let id: String
    public var title: String
    public var year: Int?
    public var platforms: [GamePlatform]
    public var cover: URL?
    public var summary: String?
    public var genres: [String]
    /// Other names it is known by (regional titles, abbreviations), for matching release names.
    public var alternativeNames: [String]
    /// "Main Game", "DLC", "Expansion", "Remaster"… (IGDB); nil when the service does not say.
    public var type: String?
    /// The service's page for it.
    public var link: URL?

    public init(
        id: String,
        title: String,
        year: Int? = nil,
        platforms: [GamePlatform] = [],
        cover: URL? = nil,
        summary: String? = nil,
        genres: [String] = [],
        alternativeNames: [String] = [],
        type: String? = nil,
        link: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.year = year
        self.platforms = platforms
        self.cover = cover
        self.summary = summary
        self.genres = genres
        self.alternativeNames = alternativeNames
        self.type = type
        self.link = link
    }

    /// Whether it is the game itself, not an add-on to one.
    public var isMainGame: Bool {
        guard let type = type?.lowercased() else { return true }
        return !["dlc", "addon", "add-on", "expansion", "bundle", "compilation", "pack", "update", "mod", "episode", "season"]
            .contains { type.contains($0) }
    }

    /// What indexers are asked: the title without a leading article (scene and No-Intro names drop or move it).
    public var indexerQuery: String {
        searchTitle.replacingOccurrences(of: #"^(the|a|an) "#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// The words indexers know it by: "The Legend of Zelda: A Link to the Past" → "The Legend of Zelda A Link to
    /// the Past"; trademarks go.
    public var searchTitle: String {
        title.replacingOccurrences(of: #"[:™®©]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Games for the Games category and the Library. Metadata services, not content sources.
///
/// | Source | Key | For |
/// |---|---|---|
/// | IGDB (`api.igdb.com/v4/games`) | the user's own Twitch app (Client ID + secret, client-credentials token) | the main source: retro and modern, platforms, alternative names, covers (`images.igdb.com/…/t_cover_big_2x/<id>.jpg`); free for non-commercial use under Twitch's Developer Services Agreement; 4 requests a second |
/// | Wikidata (`query.wikidata.org/sparql`, full-text search of video game items) | none | works before any setup: title, year, platforms, description; no covers |
///
/// Both are asked at once; one failing is fine while the other answers. The same game from both is IGDB's row.
public struct GameMetadata: Sendable {
    public struct IGDBCredentials: Sendable, Hashable {
        public var clientID: String
        public var clientSecret: String

        public init(clientID: String, clientSecret: String) {
            self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static let igdbURL = URL(string: "https://api.igdb.com/v4/")!
    static let tokenURL = URL(string: "https://id.twitch.tv/oauth2/token")!
    static let wikidataURL = URL(string: "https://query.wikidata.org/sparql")!
    /// Wikimedia refuses clients that do not name themselves and a way to reach their author.
    static let userAgent = "Dove/1.0 ( https://github.com/lakafior )"
    static let limit = 30

    public let igdb: IGDBCredentials?
    public let usesWikidata: Bool
    private let transport: any HTTPTransport
    private let tokens: TwitchTokens

    public init(igdb: IGDBCredentials?, usesWikidata: Bool = true, transport: any HTTPTransport = URLSession.shared) {
        self.init(igdb: igdb, usesWikidata: usesWikidata, transport: transport, tokens: .shared)
    }

    init(igdb: IGDBCredentials?, usesWikidata: Bool = true, transport: any HTTPTransport, tokens: TwitchTokens) {
        self.igdb = igdb
        self.usesWikidata = usesWikidata
        self.transport = transport
        self.tokens = tokens
    }

    /// Games for the words typed, ranked by `GameMatcher.rank`.
    public func search(_ query: String) async throws -> [GameSummary] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return [] }
        async let fromIGDB = Self.result { igdb == nil ? [] : try await searchIGDB(words) }
        async let fromWikidata = Self.result { usesWikidata ? try await searchWikidata(words) : [] }
        let results = [await fromIGDB, await fromWikidata]
        let found = results.compactMap { try? $0.get() }
        if found.allSatisfy(\.isEmpty), let failure = results.lazy.compactMap(\.failure).first { throw failure }
        return GameMatcher.rank(GameMatcher.merge(found.first ?? [], found.dropFirst().first ?? []), for: words)
    }

    /// Checks IGDB credentials: a token, then one search.
    public func validateIGDB() async throws {
        _ = try await searchIGDB("zelda")
    }

    private static func result<T: Sendable>(_ work: () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    // MARK: IGDB

    func searchIGDB(_ words: String) async throws -> [GameSummary] {
        guard let igdb else { return [] }
        let escaped = words.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        let body = """
        search "\(escaped)"; fields name,alternative_names.name,first_release_date,platforms.name,cover.image_id,\
        summary,genres.name,game_type.type,url; where version_parent = null; limit \(Self.limit);
        """
        let games: [IGDBGame] = try await postIGDB("games", body: body, credentials: igdb, retry: true)
        return games.map(\.gameSummary)
    }

    private func postIGDB<T: Decodable>(_ endpoint: String, body: String, credentials: IGDBCredentials, retry: Bool) async throws -> T {
        let token = try await tokens.token(for: credentials, transport: transport)
        var request = URLRequest(url: Self.igdbURL.appending(path: endpoint))
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue(credentials.clientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        // A token revoked or expired early: forget it and try once with a new one.
        if response.statusCode == 401, retry {
            await tokens.forget(credentials)
            return try await postIGDB(endpoint, body: body, credentials: credentials, retry: false)
        }
        if response.statusCode == 429 { throw BackendError.rateLimited }
        if let error = response.backendError { throw error }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BackendError.invalidResponse
        }
    }

    // MARK: Wikidata

    func searchWikidata(_ words: String) async throws -> [GameSummary] {
        var components = URLComponents(url: Self.wikidataURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: Self.sparql(words))]
        var request = URLRequest(url: components.url!)
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.send(request)
        if let error = response.backendError { throw error }
        guard let answer = try? JSONDecoder().decode(SPARQLAnswer.self, from: data) else { throw BackendError.invalidResponse }
        return answer.results.bindings.compactMap(\.summary)
    }

    /// Full-text search of items that are video games (`P31 = Q7889`), with release date (P577) and platforms (P400).
    /// Labels in English, else Wikidata's language-neutral `mul` (some games have only that).
    static func sparql(_ words: String) -> String {
        let escaped = words.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        return """
        SELECT ?item ?itemLabel ?itemDescription (MIN(?date) AS ?released) \
        (GROUP_CONCAT(DISTINCT ?platformLabel; separator="|") AS ?platforms) WHERE {
          SERVICE wikibase:mwapi {
            bd:serviceParam wikibase:endpoint "www.wikidata.org"; wikibase:api "Search";
              mwapi:srsearch "\(escaped) haswbstatement:P31=Q7889"; mwapi:srlimit "20".
            ?item wikibase:apiOutputItem mwapi:title.
            ?num wikibase:apiOrdinal true.
          }
          OPTIONAL { ?item wdt:P577 ?date. }
          OPTIONAL { ?item wdt:P400 ?platform. ?platform rdfs:label ?platformLabel. FILTER(LANG(?platformLabel) IN ("en", "mul")) }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "en,mul". }
        } GROUP BY ?item ?itemLabel ?itemDescription ?num ORDER BY ?num
        """
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// Twitch app tokens (client credentials), kept in memory per Client ID until shortly before they expire.
actor TwitchTokens {
    static let shared = TwitchTokens()

    private var tokens: [GameMetadata.IGDBCredentials: (value: String, expires: Date)] = [:]

    func token(for credentials: GameMetadata.IGDBCredentials, transport: any HTTPTransport) async throws -> String {
        if let token = tokens[credentials], token.expires > .now { return token.value }
        var components = URLComponents(url: GameMetadata.tokenURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "client_secret", value: credentials.clientSecret),
            URLQueryItem(name: "grant_type", value: "client_credentials"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let (data, response) = try await transport.send(request)
        // Twitch answers a wrong ID or secret with 400 or 403.
        if [400, 401, 403].contains(response.statusCode) {
            throw BackendError.api(message: "Twitch did not accept the Client ID and secret.")
        }
        if let error = response.backendError { throw error }
        guard let answer = try? JSONDecoder().decode(TwitchToken.self, from: data) else { throw BackendError.invalidResponse }
        tokens[credentials] = (answer.accessToken, Date.now.addingTimeInterval(TimeInterval(max(answer.expiresIn - 300, 60))))
        return answer.accessToken
    }

    func forget(_ credentials: GameMetadata.IGDBCredentials) {
        tokens[credentials] = nil
    }
}

private struct TwitchToken: Decodable {
    let accessToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

struct IGDBGame: Decodable {
    struct Named: Decodable { let name: String? }
    struct Cover: Decodable { let imageID: String?
        enum CodingKeys: String, CodingKey { case imageID = "image_id" }
    }
    struct GameType: Decodable { let type: String? }

    let id: Int
    let name: String
    let alternativeNames: [Named]?
    let firstReleaseDate: Int?
    let platforms: [Named]?
    let cover: Cover?
    let summary: String?
    let genres: [Named]?
    let gameType: GameType?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id, name, platforms, cover, summary, genres, url
        case alternativeNames = "alternative_names"
        case firstReleaseDate = "first_release_date"
        case gameType = "game_type"
    }

    var gameSummary: GameSummary {
        let year = firstReleaseDate.map { Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: TimeInterval($0))) }
        let platforms = (platforms ?? []).compactMap { $0.name.flatMap(GamePlatform.init(serviceName:)) }
        return GameSummary(
            id: "igdb:\(id)",
            title: name,
            year: year,
            platforms: platforms.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
            cover: cover?.imageID.flatMap { URL(string: "https://images.igdb.com/igdb/image/upload/t_cover_big_2x/\($0).jpg") },
            summary: summary,
            genres: (genres ?? []).compactMap(\.name),
            alternativeNames: (alternativeNames ?? []).compactMap(\.name),
            type: gameType?.type,
            link: url.flatMap(URL.init(string:))
        )
    }
}

struct SPARQLAnswer: Decodable {
    struct Results: Decodable { let bindings: [Binding] }
    struct Value: Decodable {
        let type: String
        let value: String
    }
    struct Binding: Decodable {
        let item: Value
        let itemLabel: Value?
        let itemDescription: Value?
        let released: Value?
        let platforms: Value?

        var summary: GameSummary? {
            guard let id = item.value.split(separator: "/").last.map(String.init), id.hasPrefix("Q"),
                  let label = itemLabel?.value, label != id else { return nil }
            // An unknown date comes as a blank node, not a date.
            let year = released.flatMap { $0.type == "literal" ? Int($0.value.prefix(4)) : nil }
            let platforms = (platforms?.value ?? "").split(separator: "|").compactMap { GamePlatform(serviceName: String($0)) }
            return GameSummary(
                id: "wd:\(id)",
                title: label,
                year: year,
                platforms: platforms.reduce(into: []) { if !$0.contains($1) { $0.append($1) } },
                summary: itemDescription?.value,
                type: itemDescription.flatMap { Self.type(from: $0.value) },
                link: URL(string: "https://www.wikidata.org/wiki/\(id)")
            )
        }
    }

    let results: Results
}

extension SPARQLAnswer.Binding {
    /// Wikidata's English description says what an item is: "2002 video game compilation", "expansion pack for…".
    static func type(from description: String) -> String? {
        let text = description.lowercased()
        if text.contains("compilation") { return "Compilation" }
        if text.contains("expansion") { return "Expansion" }
        if text.contains("downloadable content") || text.range(of: #"\bdlc\b"#, options: .regularExpression) != nil { return "DLC" }
        return nil
    }
}

/// Ranking, merging and matching games.
public enum GameMatcher {
    /// Lowercased words without punctuation, articles kept: "The Legend of Zelda: A Link to the Past" →
    /// ["the", "legend", "of", "zelda", "a", "link", "to", "the", "past"].
    static func words(_ text: String) -> [String] {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Every name of a game, normalised and without a leading article.
    static func names(_ game: GameSummary) -> [String] {
        ([game.title] + game.alternativeNames).map(bare).filter { !$0.isEmpty }
    }

    /// The best fit to the words first: a name that is exactly the words → every word in the title → share of the
    /// words found → main games before add-ons and compilations → fewest title words the query does not name ("A
    /// Link to the Past" before "A Link to the Past and Four Swords"); otherwise the services' own order.
    public static func rank(_ games: [GameSummary], for query: String) -> [GameSummary] {
        let wanted = words(query)
        let normalized = bare(query)
        func score(_ game: GameSummary) -> (Int, Int, Double, Int, Int) {
            let exact = names(game).contains(normalized) ? 1 : 0
            let title = Set(([game.title] + game.alternativeNames).flatMap(words))
            let found = wanted.filter(title.contains).count
            let all = !wanted.isEmpty && found == wanted.count ? 1 : 0
            let extra = Set(words(game.title)).subtracting(wanted).count
            return (exact, all, wanted.isEmpty ? 0 : Double(found) / Double(wanted.count), game.isMainGame ? 1 : 0, -extra)
        }
        return games.enumerated()
            .map { (offset: $0.offset, game: $0.element, score: score($0.element)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.game)
    }

    /// One row per game: IGDB's, with Wikidata's description and platforms when it lacks them; games only Wikidata
    /// knows are added. The same game = a name in common and years at most one apart (or one unknown).
    /// Wikidata also lists ports under the original's name (A Link to the Past for SNES, 1991, and for GBA, no date):
    /// one of them stays, the one with a year, so the answer does not depend on which came first.
    public static func merge(_ igdb: [GameSummary], _ wikidata: [GameSummary]) -> [GameSummary] {
        var kept: [GameSummary] = []
        for game in wikidata {
            guard let index = kept.firstIndex(where: { !Set(names($0)).isDisjoint(with: names(game)) }) else {
                kept.append(game)
                continue
            }
            if kept[index].year == nil, game.year != nil { kept[index] = game }
        }
        var merged = igdb
        for game in kept {
            let names = Set(Self.names(game))
            if let index = merged.prefix(igdb.count).firstIndex(where: { other in
                !names.isDisjoint(with: Self.names(other))
                    && (game.year == nil || other.year == nil || abs(game.year! - other.year!) <= 1)
            }) {
                if merged[index].summary == nil { merged[index].summary = game.summary }
                if merged[index].platforms.isEmpty { merged[index].platforms = game.platforms }
            } else {
                merged.append(game)
            }
        }
        return merged
    }

    /// The search result that is the guessed game, or none (a missing cover beats a wrong one): a name that is the
    /// guessed title, else the longest name the guessed title starts with (from 4 letters: "Elden Ring" for "Elden
    /// Ring Shadow of the Erdtree" when the add-on is not listed); the platform must fit when both are known.
    public static func best(_ results: [GameSummary], for guess: GameGuess) -> GameSummary? {
        let wanted = bare(guess.title)
        guard wanted.count >= 2 else { return nil }
        let candidates = results.filter { game in
            guard let platform = guess.platform, !game.platforms.isEmpty else { return true }
            return game.platforms.contains(platform)
        }
        if let exact = candidates.first(where: { names($0).contains(wanted) }) { return exact }
        return candidates
            .compactMap { game in names(game).filter { $0.count >= 4 && wanted.hasPrefix($0) }.max { $0.count < $1.count }.map { (game, $0.count) } }
            .max { $0.1 < $1.1 }?.0
    }
}

extension GameMatcher {
    /// Whether a release name is this game: the guessed title is one of its names (without an article: "Legend of
    /// Zelda A Link to the Past" is "The Legend of Zelda: A Link to the Past"), or starts with one (repacks with
    /// DLC, "Elden Ring Shadow of the Erdtree" on Elden Ring's screen).
    public static func matches(_ releaseName: String, _ game: GameSummary) -> Bool {
        let guessed = bare(GameGuess(releaseName: releaseName).title)
        guard guessed.count >= 2 else { return false }
        return ([game.title] + game.alternativeNames).map(bare).contains { name in
            name == guessed || (name.count >= 4 && guessed.hasPrefix(name))
        }
    }

    /// Normalised, without a leading article.
    static func bare(_ title: String) -> String {
        MediaGuess.normalize(title.replacingOccurrences(of: #"^(the|a|an)\s+"#, with: "", options: [.regularExpression, .caseInsensitive]))
    }
}

extension StreamGroup {
    /// A game's screen: its releases first, the rest of the indexers' answer behind them.
    public static func split(_ groups: [StreamGroup], for game: GameSummary) -> (thisGame: [StreamGroup], other: [StreamGroup]) {
        var thisGame: [StreamGroup] = [], other: [StreamGroup] = []
        for group in groups {
            if GameMatcher.matches(group.title, game) { thisGame.append(group) } else { other.append(group) }
        }
        return (thisGame, other)
    }
}

extension GameMetadata {
    /// The game a library item is, from its guessed title and platform; nil when nothing fits.
    public func match(_ guess: GameGuess) async throws -> GameSummary? {
        GameMatcher.best(try await search(guess.query), for: guess)
    }
}
