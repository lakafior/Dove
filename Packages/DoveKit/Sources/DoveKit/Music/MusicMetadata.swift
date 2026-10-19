import Foundation

/// An album (or EP, single…) as a metadata service describes it: real title, artists, year, cover.
public struct AlbumSummary: Identifiable, Sendable, Hashable, Codable {
    /// `mb:<release group MBID>` (MusicBrainz).
    public let id: String
    public var title: String
    public var artists: [String]
    public var year: Int?
    public var cover: URL?
    /// `Album`, `EP`, `Single`, plus what kind of album when it is one: `Compilation`, `Live`, `Soundtrack`…
    public var type: String?
    /// One release of it, for the track list.
    public var releaseID: String?
    /// The same album in a catalog (`AlbumCatalog`, e.g. `am:1440833098` for Apple Music): its tracks when
    /// MusicBrainz names no release.
    public var catalogID: String?
    /// The service's page for it.
    public var link: URL?

    public init(
        id: String,
        title: String,
        artists: [String] = [],
        year: Int? = nil,
        cover: URL? = nil,
        type: String? = nil,
        releaseID: String? = nil,
        catalogID: String? = nil,
        link: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.year = year
        self.cover = cover
        self.type = type
        self.releaseID = releaseID
        self.catalogID = catalogID
        self.link = link
    }

    /// "Daft Punk" or "Various Artists".
    public var artist: String? { artists.isEmpty ? nil : artists.joined(separator: ", ") }

    /// The words indexers know it by: without "(Deluxe Edition)" or "[Remastered]".
    public var searchTitle: String {
        let main = title.replacingOccurrences(
            of: #"\s*[\(\[][^\)\]]*(edition|remaster|deluxe|expanded|anniversary|bonus)[^\)\]]*[\)\]]\s*$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)
        return main.isEmpty ? title : main
    }
}

/// One track of an album's release.
public struct AlbumTrack: Sendable, Hashable, Identifiable {
    public let id: String
    public var disc: Int
    public var position: Int
    public var title: String
    public var duration: TimeInterval?

    public init(id: String, disc: Int = 1, position: Int, title: String, duration: TimeInterval? = nil) {
        self.id = id
        self.disc = disc
        self.position = position
        self.title = title
        self.duration = duration
    }
}

/// A second album source the app plugs in (Apple Music through MusicKit lives in the app: it needs the device's
/// authorization and cannot run in DoveKit's tests). Albums carry their catalog ID in `id` (`am:…`) and their
/// kind in `type` (`Album` is a studio album; `Single`, `EP`, `Compilation`, `Live`…).
public protocol AlbumCatalog: Sendable {
    /// Shown in rows and errors: "Apple Music".
    var name: String { get }
    /// Whether an album ID (`am:…`, `plugin:<id>:…`) is one of this catalog's.
    func owns(_ albumID: String) -> Bool
    func albums(matching query: String) async throws -> [AlbumSummary]
    func tracks(ofAlbum id: String) async throws -> [AlbumTrack]
}

/// Albums for the Music category. Metadata services, not content sources.
///
/// | Source | Key | For |
/// |---|---|---|
/// | MusicBrainz (`musicbrainz.org/ws/2`) | none | albums (release groups), artists, years, track lists; at most one call a second, a User-Agent required |
/// | Cover Art Archive (`coverartarchive.org/release-group/<MBID>/front-250`) | none | covers, as image URLs: no call until a row shows it |
/// | `AlbumCatalog`s the app passes (Apple Music) | the user's permission | asked at the same time; the same album from both is one row (MusicBrainz's, with the catalog's cover), albums only the catalog has are added |
///
/// MusicBrainz answers "busy" (503) when it is loaded or called too fast: Dove waits its turn (`MusicBrainzGate`)
/// and asks again three times, waiting longer each time, before it gives up.
public struct MusicMetadata: Sendable {
    static let baseURL = URL(string: "https://musicbrainz.org/ws/2/")!
    /// MusicBrainz asks for an application name and a way to reach its author.
    static let userAgent = "Dove/1.0 ( https://github.com/lakafior )"
    /// An artist's name alone should bring its discography.
    static let limit = 40

    private let transport: any HTTPTransport
    private let gate: MusicBrainzGate
    public let catalogs: [any AlbumCatalog]

    public init(catalogs: [any AlbumCatalog] = [], transport: any HTTPTransport = URLSession.shared) {
        self.init(catalogs: catalogs, transport: transport, gate: .shared)
    }

    init(catalogs: [any AlbumCatalog] = [], transport: any HTTPTransport, gate: MusicBrainzGate) {
        self.catalogs = catalogs
        self.transport = transport
        self.gate = gate
    }

    /// Albums for the words typed ("discovery", "radiohead", "daft punk discovery"): the words are looked for in
    /// album titles and artist names alike, then ranked by `AlbumMatcher.rank`.
    /// Words that are an artist's name ("radiohead") also ask for that artist's official albums: the plain search
    /// favours the word in titles (tributes, demos called "Radiohead") and missed the band's studio albums.
    /// The catalogs are asked at the same time; one source failing is fine while another answers.
    public func search(_ query: String) async throws -> [AlbumSummary] {
        async let musicBrainz = Self.result { try await searchMusicBrainz(query) }
        var fromCatalogs: [AlbumSummary] = []
        var failure: (any Error)?
        await withTaskGroup(of: Result<[AlbumSummary], any Error>.self) { group in
            for catalog in catalogs {
                group.addTask { await Self.result { try await catalog.albums(matching: query) } }
            }
            for await result in group {
                switch result {
                case .success(let albums): fromCatalogs += albums
                case .failure(let error): failure = failure ?? error
                }
            }
        }
        let groups: [MusicBrainzReleaseGroup]
        switch await musicBrainz {
        case .success(let found): groups = found
        case .failure(let error):
            guard !fromCatalogs.isEmpty else { throw error }
            groups = []
        }
        if groups.isEmpty, fromCatalogs.isEmpty, let failure { throw failure }
        return AlbumMatcher.rank(AlbumMatcher.merge(groups.map(\.candidate), fromCatalogs), for: query)
    }

    private static func result<T>(_ work: () async throws -> T) async -> Result<T, any Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private func searchMusicBrainz(_ query: String) async throws -> [MusicBrainzReleaseGroup] {
        let page = try await get(MusicBrainzReleaseGroups.self, "release-group", [
            "query": Self.luceneQuery(query), "fmt": "json", "limit": String(Self.limit),
        ])
        var groups = page.releaseGroups
        if let artistID = Self.artist(namedBy: query, in: groups),
           let albums = try? await get(MusicBrainzReleaseGroups.self, "release-group", [
               "query": "arid:\(artistID) AND primarytype:album AND status:official", "fmt": "json", "limit": "100",
           ]) {
            let known = Set(albums.releaseGroups.map(\.id))
            groups = albums.releaseGroups + groups.filter { !known.contains($0.id) }
        }
        return groups
    }

    /// The MBID of the artist whose name is exactly the words typed, if a result credits one.
    static func artist(namedBy query: String, in groups: [MusicBrainzReleaseGroup]) -> String? {
        let wanted = AlbumMatcher.words(query)
        guard !wanted.isEmpty else { return nil }
        return groups.lazy
            .flatMap { $0.artistCredit ?? [] }
            .first { AlbumMatcher.words($0.artist?.name ?? $0.name) == wanted }?
            .artist?.id
    }

    /// `releasegroup:(…) OR artist:(…)`: a bare query only searches titles, so "radiohead" found albums called
    /// "Radiohead" and none of the band's. Lucene's own characters are escaped.
    static func luceneQuery(_ words: String) -> String {
        let special = Set(#"+-&|!(){}[]^"~*?:\/"#)
        let escaped = words.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
        return "releasegroup:(\(escaped)) OR artist:(\(escaped))"
    }

    /// The tracks of the album's MusicBrainz release, in disc and track order; the catalog's when MusicBrainz
    /// names no release or fails. Empty when neither has them.
    public func tracks(of album: AlbumSummary) async throws -> [AlbumTrack] {
        let catalogID = album.catalogID ?? (album.id.hasPrefix("mb:") ? nil : album.id)
        let catalog = catalogID.flatMap { id in catalogs.first { $0.owns(id) }.map { ($0, id) } }
        guard let releaseID = album.releaseID else {
            guard let (catalog, id) = catalog else { return [] }
            return try await catalog.tracks(ofAlbum: id)
        }
        do {
            let release = try await get(MusicBrainzRelease.self, "release/\(releaseID)", ["inc": "recordings", "fmt": "json"])
            return release.media.flatMap { medium in
                (medium.tracks ?? []).map {
                    AlbumTrack(id: $0.id, disc: medium.position, position: $0.position, title: $0.title, duration: $0.length.map { Double($0) / 1000 })
                }
            }
        } catch {
            guard let (catalog, id) = catalog else { throw error }
            return try await catalog.tracks(ofAlbum: id)
        }
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, _ parameters: [String: String]) async throws -> T {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        var attempt = 0
        while true {
            await gate.wait()
            let (data, response) = try await transport.send(request)
            if response.statusCode == 503 || response.statusCode == 429 {
                attempt += 1
                guard attempt <= 3 else { throw BackendError.api(message: "MusicBrainz is busy. Try again in a moment.") }
                await gate.backOff(attempt)
                continue
            }
            if let error = response.backendError { throw error }
            do {
                return try JSONDecoder().decode(type, from: data)
            } catch {
                throw BackendError.invalidResponse
            }
        }
    }
}

/// One MusicBrainz call at a time, a second apart, for the whole app (their limit is per client IP).
actor MusicBrainzGate {
    static let shared = MusicBrainzGate(interval: .milliseconds(1100))

    private let interval: Duration
    private var next = ContinuousClock.now

    init(interval: Duration) {
        self.interval = interval
    }

    func wait() async {
        let start = max(next, .now)
        next = start + interval
        try? await Task.sleep(until: start, clock: .continuous)
    }

    /// After a "busy" answer: the next call waits longer each time (it is busy about one call in four, sometimes
    /// several in a row).
    func backOff(_ attempt: Int) {
        next = max(next, .now) + interval * attempt
    }
}

/// Picks the albums that fit the words typed.
public enum AlbumMatcher {
    /// Albums whose whole title or whole artist name the words hold, the most words that way first ("ok computer"
    /// is Radiohead's album, not "Outside Computer" by "OK Vancouver OK"; "radiohead" is the band's albums, not
    /// "Homage to Radiohead"); then the most words found anywhere in title and artist (for words that name
    /// only part of a title); then ones with an official release, then studio albums (no single, demo, live or
    /// remix), then the ones released most often; MusicBrainz's order otherwise.
    static func rank(_ candidates: [Candidate], for query: String) -> [AlbumSummary] {
        let wanted = Set(words(query))
        return candidates.enumerated()
            .map { index, candidate -> (index: Int, album: AlbumSummary, key: [Int]) in
                let album = candidate.album
                let title = Set(words(album.searchTitle))
                let artists = album.artists.map { Set(words($0)) }
                let named = ([title] + artists).filter { !$0.isEmpty && $0.isSubset(of: wanted) }.reduce(Set<String>()) { $0.union($1) }
                let coverage = wanted.intersection(artists.reduce(title) { $0.union($1) }).count
                return (index, album, [named.count, coverage, candidate.official ? 1 : 0, candidate.studio ? 1 : 0, candidate.releases])
            }
            .sorted { $0.key != $1.key ? $0.key.lexicographicallyPrecedes($1.key, by: >) : $0.index < $1.index }
            .map(\.album)
    }

    /// An album with what ranking needs to know besides its words.
    struct Candidate {
        var album: AlbumSummary
        var official = true
        var studio: Bool
        /// How often it was released (MusicBrainz's release count; 0 from a catalog).
        var releases = 0
    }

    /// MusicBrainz's albums with the catalogs' ones: the same album (artist and title words, the year when both
    /// give one) becomes MusicBrainz's entry with the catalog's ID and cover (catalog covers always exist; Cover Art
    /// Archive has none for many albums); the rest are added after.
    static func merge(_ candidates: [Candidate], _ catalog: [AlbumSummary]) -> [Candidate] {
        var merged = candidates
        for album in catalog {
            let key = mergeKey(album)
            if let index = merged.firstIndex(where: {
                mergeKey($0.album) == key && $0.album.catalogID == nil
                    && ($0.album.year == nil || album.year == nil || abs($0.album.year! - album.year!) <= 1)
            }) {
                merged[index].album.catalogID = album.id
                merged[index].album.cover = album.cover ?? merged[index].album.cover
            } else if !merged.contains(where: { $0.album.catalogID == album.id }) {
                merged.append(Candidate(album: album, studio: album.type == "Album"))
            }
        }
        return merged
    }

    private static func mergeKey(_ album: AlbumSummary) -> String {
        (words(album.artists.first ?? "") + ["|"] + words(album.searchTitle)).joined(separator: " ")
    }

    /// Lowercased words without diacritics ("AC/DC" → "ac", "dc").
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Whether a release name is this album: its title, and its artist unless the title is long enough to say it
    /// alone or the album is a various-artists compilation.
    public static func matches(_ releaseName: String, _ album: AlbumSummary) -> Bool {
        let name = MediaGuess.normalize(releaseName)
        let title = MediaGuess.normalize(album.searchTitle)
        guard title.count >= 2, name.contains(title) else { return false }
        let artists = album.artists.map(MediaGuess.normalize).filter { !$0.isEmpty }
        if artists.contains(where: { name.contains($0) }) { return true }
        let various = artists.isEmpty || artists.contains("variousartists")
        return various ? title.count >= 6 : false
    }
}

extension StreamGroup {
    /// An album's releases screen: what the indexers returned that is this album, then the rest of their answer.
    public static func split(_ groups: [StreamGroup], for album: AlbumSummary) -> (thisAlbum: [StreamGroup], other: [StreamGroup]) {
        var thisAlbum: [StreamGroup] = [], other: [StreamGroup] = []
        for group in groups {
            if AlbumMatcher.matches(group.title, album) { thisAlbum.append(group) } else { other.append(group) }
        }
        return (thisAlbum, other)
    }
}

// MARK: - MusicBrainz

struct MusicBrainzReleaseGroups: Decodable {
    let releaseGroups: [MusicBrainzReleaseGroup]

    enum CodingKeys: String, CodingKey {
        case releaseGroups = "release-groups"
    }
}

struct MusicBrainzReleaseGroup: Decodable {
    struct Credit: Decodable {
        struct Artist: Decodable {
            let id: String
            let name: String
        }

        let name: String
        let joinphrase: String?
        let artist: Artist?
    }

    struct Release: Decodable {
        let id: String
        let status: String?
    }

    let id: String
    let title: String
    let primaryType: String?
    let secondaryTypes: [String]?
    let firstReleaseDate: String?
    let artistCredit: [Credit]?
    let releases: [Release]?
    let count: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, releases, count
        case primaryType = "primary-type"
        case secondaryTypes = "secondary-types"
        case firstReleaseDate = "first-release-date"
        case artistCredit = "artist-credit"
    }

    var candidate: AlbumMatcher.Candidate {
        AlbumMatcher.Candidate(
            album: summary,
            official: releases?.contains { $0.status == "Official" } ?? true,
            studio: primaryType == "Album" && (secondaryTypes ?? []).isEmpty,
            releases: count ?? 0
        )
    }

    var summary: AlbumSummary {
        let type = secondaryTypes?.first ?? primaryType
        let release = releases?.first { $0.status == "Official" } ?? releases?.first
        return AlbumSummary(
            id: "mb:\(id)",
            title: title,
            artists: (artistCredit ?? []).map(\.name),
            year: firstReleaseDate.flatMap { Int($0.prefix(4)) },
            cover: URL(string: "https://coverartarchive.org/release-group/\(id)/front-250"),
            type: type,
            releaseID: release?.id,
            link: URL(string: "https://musicbrainz.org/release-group/\(id)")
        )
    }
}

struct MusicBrainzRelease: Decodable {
    struct Medium: Decodable {
        let position: Int
        /// Missing on some media (data discs).
        let tracks: [Track]?
    }

    struct Track: Decodable {
        let id: String
        let position: Int
        let title: String
        let length: Int?
    }

    let media: [Medium]
}
