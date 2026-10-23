import Foundation

/// Movies and series. Stremio addons know more types (`anime`, `tv`, `channel`…); Dove searches these two.
public enum MediaType: String, Sendable, Codable, CaseIterable, Hashable {
    case movie
    case series
}

/// One search result or catalog entry.
public struct MediaSummary: Identifiable, Sendable, Hashable, Codable {
    /// Addon-scoped ID: `tt1160419`, `tmdb:693134`, `kitsu:1`…
    public let id: String
    public let type: MediaType
    public var name: String
    public var releaseInfo: String?
    public var poster: URL?
    public var background: URL?
    public var description: String?
    public var imdbRating: String?

    public init(
        id: String,
        type: MediaType,
        name: String,
        releaseInfo: String? = nil,
        poster: URL? = nil,
        background: URL? = nil,
        description: String? = nil,
        imdbRating: String? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.releaseInfo = releaseInfo
        self.poster = poster
        self.background = background
        self.description = description
        self.imdbRating = imdbRating
    }
}

/// Full metadata, with episodes for series.
public struct MediaDetail: Sendable, Hashable {
    public var summary: MediaSummary
    public var genres: [String]
    public var runtime: String?
    public var logo: URL?
    public var episodes: [Episode]
    /// Each season's own name, overview, poster and air date, by season number (0 = specials). Empty when the
    /// source has none (only TMDB fills it).
    public var seasonInfo: [Int: SeasonInfo]

    public init(
        summary: MediaSummary,
        genres: [String] = [],
        runtime: String? = nil,
        logo: URL? = nil,
        episodes: [Episode] = [],
        seasonInfo: [Int: SeasonInfo] = [:]
    ) {
        self.summary = summary
        self.genres = genres
        self.runtime = runtime
        self.logo = logo
        self.episodes = episodes
        self.seasonInfo = seasonInfo
    }

    /// Regular seasons in order; season 0 (specials) last.
    public var seasons: [Int] {
        let all = Set(episodes.map(\.season))
        return all.filter { $0 > 0 }.sorted() + (all.contains(0) ? [0] : [])
    }

    public func episodes(inSeason season: Int) -> [Episode] {
        episodes.filter { $0.season == season }.sorted { $0.number < $1.number }
    }
}

/// One season of a series as its metadata source describes it (TMDB `seasons[]`).
public struct SeasonInfo: Sendable, Hashable, Codable {
    public var name: String?
    public var overview: String?
    /// Poster image URL (TMDB `w342`).
    public var poster: URL?
    public var episodeCount: Int?
    public var airDate: Date?

    public init(name: String? = nil, overview: String? = nil, poster: URL? = nil, episodeCount: Int? = nil, airDate: Date? = nil) {
        self.name = name
        self.overview = overview
        self.poster = poster
        self.episodeCount = episodeCount
        self.airDate = airDate
    }
}

public struct Episode: Identifiable, Sendable, Hashable {
    /// Stream ID for this episode, e.g. `tt11280740:1:1`.
    public let id: String
    public let season: Int
    public let number: Int
    public var title: String?
    public var overview: String?
    public var thumbnail: URL?
    public var released: Date?

    public init(id: String, season: Int, number: Int, title: String? = nil, overview: String? = nil, thumbnail: URL? = nil, released: Date? = nil) {
        self.id = id
        self.season = season
        self.number = number
        self.title = title
        self.overview = overview
        self.thumbnail = thumbnail
        self.released = released
    }
}

/// One playable or addable source for a movie or an episode, from any stream addon.
public struct StreamCandidate: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// Resolved through a debrid service (the `url`, if any, adds it there on first request).
        case debrid
        case usenet
        /// Plain HTTP (Easynews, direct links).
        case http
        /// Torrent without a debrid link: only `infoHash` (+ `fileIndex`).
        case p2p
        case unknown
    }

    public let id: String
    public var kind: Kind
    /// Release file name when known, otherwise the addon's title line.
    public var title: String
    /// The addon's own display text (`name` + `description`), cleaned of invisible padding.
    public var label: String
    public var size: Int64?
    public var folderName: String?
    public var folderSize: Int64?
    public var infoHash: String?
    /// Index of the file inside the torrent; nil when unknown (`-1` upstream).
    public var fileIndex: Int?
    /// Playback/resolve URL. Often embeds the user's tokens: never log or persist it.
    public var url: URL?
    public var nzbURL: URL?
    /// `realdebrid`, `torbox`, `offcloud`, `nzbdav`… as named by the addon.
    public var service: String?
    public var cached: Bool?
    public var bingeGroup: String?
    public var traits: StreamTraits?
    /// Newznab category (`3010`…) for results from Dove's own indexers.
    public var category: Int?
    /// A Torznab result's `.torrent` link (kept with an info hash too: only the file says whether the torrent
    /// is private, and a private one needs its tracker's passkey). It carries the indexer's API key and
    /// may point to a host only the phone reaches: resolve it with `IndexerTorrent.prepare` before adding.
    public var torrentURL: URL?
    /// Seeders the indexer or addon last saw (Torznab, AIOStreams, Torrentio's 👤).
    public var seeders: Int?
    /// Who answered Dove: "AIOStreams", a Stremio addon's name ("Torrentio"), or Dove's own indexer ("Jackett").
    public var provider: String?
    /// The addon inside AIOStreams that found it ("Torrentio", "Comet").
    public var addon: String?
    /// The tracker or Usenet indexer behind it: Jackett's and Prowlarr's per-result indexer, AIOStreams' `indexer`,
    /// Torrentio's ⚙️ line.
    public var tracker: String?
    /// The tracker is private (Jackett `type`, Prowlarr, AIOStreams `private`). Nil when nobody said.
    public var isPrivate: Bool?
    /// When the release was posted (Torznab/Newznab `pubDate`, AIOStreams `age`).
    public var published: Date?
    /// Headers the `url` needs (a Stremio stream's `behaviorHints.proxyHeaders.request`: cookies, referer).
    /// Players cannot send them; Dove's own downloads do. May hold session cookies: never log or persist.
    public var headers: [String: String]
    /// Mb/s as the addon prints it (`~2.6 Mbps`, AIOStreams' `29.1 ᴹᵇᵖˢ`); nil when not given.
    public var bitrate: Double?

    public init(
        id: String,
        kind: Kind,
        title: String,
        label: String = "",
        size: Int64? = nil,
        folderName: String? = nil,
        folderSize: Int64? = nil,
        infoHash: String? = nil,
        fileIndex: Int? = nil,
        url: URL? = nil,
        nzbURL: URL? = nil,
        service: String? = nil,
        cached: Bool? = nil,
        bingeGroup: String? = nil,
        traits: StreamTraits? = nil,
        category: Int? = nil,
        torrentURL: URL? = nil,
        seeders: Int? = nil,
        provider: String? = nil,
        addon: String? = nil,
        tracker: String? = nil,
        isPrivate: Bool? = nil,
        published: Date? = nil,
        headers: [String: String] = [:],
        bitrate: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.label = label
        self.size = size
        self.folderName = folderName
        self.folderSize = folderSize
        self.infoHash = infoHash
        self.fileIndex = fileIndex
        self.url = url
        self.nzbURL = nzbURL
        self.service = service
        self.cached = cached
        self.bingeGroup = bingeGroup
        self.traits = traits
        self.category = category
        self.torrentURL = torrentURL
        self.seeders = seeders
        self.provider = provider
        self.addon = addon
        self.tracker = tracker
        self.isPrivate = isPrivate
        self.published = published
        self.headers = headers
        self.bitrate = bitrate
    }

    /// An external player can open the link: no headers needed, and not DASH (Infuse and VLC take HLS).
    public var playsInPlayers: Bool {
        guard headers.isEmpty, let url else { return false }
        return ![title, url.lastPathComponent].contains { name in
            let name = name.lowercased()
            return name.hasSuffix(".mpd") || name.hasSuffix(".ism")
        }
    }

    /// Where it came from, outermost first, without repeats: ["AIOStreams", "Torrentio", "1337x"], ["Jackett", "TorrentLeech"].
    public var origin: [String] {
        var path: [String] = []
        for name in [provider, addon, tracker].compactMap({ $0?.trimmingCharacters(in: .whitespaces) }) where !name.isEmpty {
            if !path.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { path.append(name) }
        }
        return path
    }

    /// What kind of thing this is, for display and filters.
    public var sourceType: SourceType {
        if kind == .usenet || nzbURL != nil { return .usenet }
        if infoHash != nil || torrentURL != nil || kind == .p2p { return .torrent }
        if kind == .http { return .web }
        return .debridLink
    }

    /// What "Add to library" sends to a backend: the torrent (whole, no file index) or the NZB.
    /// An indexer's `.torrent` beats a bare magnet: it names the trackers and tells private torrents apart.
    public var librarySource: Source? {
        if let torrentURL { return .torrentURL(torrentURL) }
        if let infoHash, !infoHash.isEmpty { return .magnet(infoHash: infoHash, name: releaseName) }
        if let nzbURL { return .nzbURL(nzbURL, name: releaseName) }
        return nil
    }

    /// A plain HTTP file Dove can download or hand to a cloud service: a `.http` stream whose link is one file,
    /// not a DASH/HLS playlist (those only play).
    public var directFile: DirectStreamFile? {
        guard kind == .http, let url else { return nil }
        let names = [title, url.lastPathComponent].map { $0.lowercased() }
        guard !names.contains(where: { name in DirectStreamFile.playlistExtensions.contains { name.hasSuffix(".\($0)") } }) else { return nil }
        return DirectStreamFile(url: url, headers: headers, name: title, size: size)
    }

    /// The release's name as the search showed it: the torrent folder, else the file or indexer title.
    /// Nil when the addon gave neither ("Stream").
    public var releaseName: String? {
        let name = (folderName ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "Stream" ? nil : name
    }

    /// The torrent folder is much bigger than this file: a season or a collection pack.
    public var isPack: Bool {
        guard let size, let folderSize, size > 0 else { return false }
        return Double(folderSize) > Double(size) * 1.5
    }
}

/// The broad kind of a source row.
public enum SourceType: String, Sendable, Hashable, CaseIterable {
    case torrent
    case usenet
    /// A debrid service's resolve link without an info hash (debrid-configured addons): play only.
    case debridLink
    /// Plain HTTP (Easynews, direct links).
    case web

    public var displayName: String {
        switch self {
        case .torrent: "Torrent"
        case .usenet: "Usenet"
        case .debridLink: "Debrid link"
        case .web: "Web"
        }
    }
}

/// Parsed release attributes (AIOStreams `parsedFile`). Useful for ranking and badges.
public struct StreamTraits: Sendable, Hashable {
    public var resolution: String?
    public var quality: String?
    public var encode: String?
    public var releaseGroup: String?
    public var visualTags: [String]
    public var audioTags: [String]
    public var languages: [String]
    public var seasons: [Int]
    public var episodes: [Int]
    /// The torrent folder holds whole seasons (and no single episode).
    public var seasonPack: Bool
    /// Seasons covered by the torrent folder; more than one means a multi-season or full-series pack.
    public var folderSeasons: [Int]

    public init(
        resolution: String? = nil,
        quality: String? = nil,
        encode: String? = nil,
        releaseGroup: String? = nil,
        visualTags: [String] = [],
        audioTags: [String] = [],
        languages: [String] = [],
        seasons: [Int] = [],
        episodes: [Int] = [],
        seasonPack: Bool = false,
        folderSeasons: [Int] = []
    ) {
        self.resolution = resolution
        self.quality = quality
        self.encode = encode
        self.releaseGroup = releaseGroup
        self.visualTags = visualTags
        self.audioTags = audioTags
        self.languages = languages
        self.seasons = seasons
        self.episodes = episodes
        self.seasonPack = seasonPack
        self.folderSeasons = folderSeasons
    }

    /// Fills fields this value lacks from another parse (e.g. the addon's traits over the file name's).
    public func merged(with other: StreamTraits) -> StreamTraits {
        StreamTraits(
            resolution: resolution ?? other.resolution,
            quality: quality ?? other.quality,
            encode: encode ?? other.encode,
            releaseGroup: releaseGroup ?? other.releaseGroup,
            visualTags: visualTags.isEmpty ? other.visualTags : visualTags,
            audioTags: audioTags.isEmpty ? other.audioTags : audioTags,
            languages: languages.isEmpty ? other.languages : languages,
            seasons: seasons.isEmpty ? other.seasons : seasons,
            episodes: episodes.isEmpty ? other.episodes : episodes,
            seasonPack: seasonPack || other.seasonPack,
            folderSeasons: folderSeasons.isEmpty ? other.folderSeasons : folderSeasons
        )
    }
}

/// A source row's link that is one whole file (see `StreamCandidate.directFile`).
public struct DirectStreamFile: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]
    /// The addon's file name (`behaviorHints.filename`), else its title line.
    public var name: String
    public var size: Int64?

    static let playlistExtensions = ["m3u8", "m3u", "mpd", "ism"]

    /// No headers needed: a cloud service can fetch it by the link alone.
    public var isPlain: Bool { headers.isEmpty }

    public var request: URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    /// A name to save it under: the file name with an extension, else the link's last component.
    public var fileName: String {
        if !(name as NSString).pathExtension.isEmpty, name != "Stream" { return name }
        let last = url.lastPathComponent
        if !(last as NSString).pathExtension.isEmpty { return last }
        return name == "Stream" ? "video.mp4" : name + ".mp4"
    }
}
