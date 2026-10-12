import Foundation

/// `manifest.json` of a Stremio addon. Only the parts Dove uses.
/// Spec: https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/manifest.md
public struct StremioManifest: Decodable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let version: String?
    public let description: String?
    public let logo: String?
    public let types: [String]
    public let idPrefixes: [String]?
    public let resources: [Resource]
    public let catalogs: [Catalog]

    /// A resource is either a bare name (`"meta"`) or an object with its own types and ID prefixes.
    public struct Resource: Decodable, Sendable, Hashable {
        public let name: String
        public let types: [String]?
        public let idPrefixes: [String]?

        public init(from decoder: any Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.name = name
                types = nil
                idPrefixes = nil
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            types = try container.decodeIfPresent([String].self, forKey: .types)
            idPrefixes = try container.decodeIfPresent([String].self, forKey: .idPrefixes)
        }

        private enum CodingKeys: String, CodingKey { case name, types, idPrefixes }
    }

    public struct Catalog: Decodable, Sendable, Hashable {
        public let type: String
        public let id: String
        public let name: String?
        public let extra: [Extra]?
        /// Legacy form of `extra`.
        public let extraSupported: [String]?
        public let extraRequired: [String]?

        public struct Extra: Decodable, Sendable, Hashable {
            public let name: String
            public let isRequired: Bool?
        }

        public var supportsSearch: Bool {
            (extra ?? []).contains { $0.name == "search" } || (extraSupported ?? []).contains("search")
        }

        /// Search alone satisfies everything the catalog requires (no mandatory genre, etc.).
        public var isPlainSearch: Bool {
            guard supportsSearch else { return false }
            let required = (extra ?? []).filter { $0.isRequired == true }.map(\.name) + (extraRequired ?? [])
            return required.allSatisfy { $0 == "search" }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, logo, types, idPrefixes, resources, catalogs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        types = try container.decodeIfPresent([String].self, forKey: .types) ?? []
        idPrefixes = try container.decodeIfPresent([String].self, forKey: .idPrefixes)
        resources = try container.decodeIfPresent([Resource].self, forKey: .resources) ?? []
        catalogs = try container.decodeIfPresent([Catalog].self, forKey: .catalogs) ?? []
    }

    public func provides(_ resource: String) -> Bool {
        resources.contains { $0.name == resource }
    }

    /// Whether a resource (`stream`, `meta`) accepts this type and ID, honouring per-resource overrides.
    public func accepts(_ resource: String, type: MediaType, id: String) -> Bool {
        guard let entry = resources.first(where: { $0.name == resource }) else { return false }
        let types = entry.types ?? self.types
        guard types.contains(type.rawValue) else { return false }
        guard let prefixes = entry.idPrefixes ?? idPrefixes else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }

    /// The catalog to search for a type: the first one that needs nothing but `search`.
    public func searchCatalog(for type: MediaType) -> Catalog? {
        catalogs.first { $0.type == type.rawValue && $0.isPlainSearch }
    }

    public var canSearch: Bool {
        provides("catalog") && MediaType.allCases.contains { searchCatalog(for: $0) != nil }
    }
}

// MARK: - Wire types

struct StremioMetasResponse: Decodable {
    let metas: [StremioMeta]
}

struct StremioMetaResponse: Decodable {
    let meta: StremioMeta
}

struct StremioMeta: Decodable {
    let id: String
    let type: String
    let name: String?
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let genres: [String]?
    let runtime: String?
    let videos: [Video]?

    struct Video: Decodable {
        let id: String
        let title: String?
        /// Cinemeta uses `name` where others use `title`.
        let name: String?
        let season: Int?
        let episode: Int?
        /// Cinemeta duplicates `episode` as `number`.
        let number: Int?
        let overview: String?
        let description: String?
        let thumbnail: String?
        let released: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description, releaseInfo, imdbRating, genres, runtime, videos
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        background = try c.decodeIfPresent(String.self, forKey: .background)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        releaseInfo = try? c.decodeIfPresent(String.self, forKey: .releaseInfo)
        // Addons disagree on the type of these; drop what does not fit instead of failing the whole response.
        imdbRating = try? c.decodeIfPresent(String.self, forKey: .imdbRating)
        genres = try? c.decodeIfPresent([String].self, forKey: .genres)
        runtime = try? c.decodeIfPresent(String.self, forKey: .runtime)
        videos = try? c.decodeIfPresent([Video].self, forKey: .videos)
    }

    var summary: MediaSummary? {
        guard let mediaType = MediaType(rawValue: type) else { return nil }
        return MediaSummary(
            id: id,
            type: mediaType,
            name: name ?? id,
            releaseInfo: releaseInfo,
            poster: poster.flatMap(URL.init(string:)),
            background: background.flatMap(URL.init(string:)),
            description: description,
            imdbRating: imdbRating
        )
    }

    var detail: MediaDetail? {
        guard let summary else { return nil }
        let episodes = (videos ?? []).compactMap { video -> Episode? in
            guard let season = video.season, let number = video.episode ?? video.number else { return nil }
            return Episode(
                id: video.id,
                season: season,
                number: number,
                title: video.title ?? video.name,
                overview: video.overview ?? video.description,
                thumbnail: video.thumbnail.flatMap(URL.init(string:)),
                released: video.released.flatMap(APIDate.parse)
            )
        }
        return MediaDetail(
            summary: summary,
            genres: genres ?? [],
            runtime: runtime,
            logo: logo.flatMap(URL.init(string:)),
            episodes: episodes
        )
    }
}

struct StremioStreamsResponse: Decodable {
    let streams: [StremioStream]
}

struct StremioStream: Decodable {
    let name: String?
    let title: String?
    let description: String?
    let url: String?
    let infoHash: String?
    let fileIdx: Int?
    let behaviorHints: Hints?

    struct Hints: Decodable {
        let filename: String?
        let bingeGroup: String?
        let videoSize: Int64?
        let folderName: String?
        let folderSize: Int64?
        let cached: Bool?
    }

    func candidate(id: String) -> StreamCandidate {
        let text = [name, description ?? title].compactMap { $0.map(StremioText.clean) }.filter { !$0.isEmpty }
        let label = text.joined(separator: "\n")
        let kind: StreamCandidate.Kind = if url != nil {
            .debrid
        } else if infoHash != nil {
            .p2p
        } else {
            .unknown
        }
        return StreamCandidate(
            id: id,
            kind: kind,
            title: behaviorHints?.filename ?? text.last?.components(separatedBy: "\n").first ?? "Stream",
            label: label,
            size: behaviorHints?.videoSize,
            folderName: behaviorHints?.folderName,
            folderSize: behaviorHints?.folderSize,
            infoHash: infoHash,
            fileIndex: fileIdx.flatMap { $0 >= 0 ? $0 : nil },
            url: url.flatMap(URL.init(string:)),
            cached: behaviorHints?.cached,
            bingeGroup: behaviorHints?.bingeGroup
        )
    }
}

enum StremioText {
    /// Formatters pad names with non-breaking and zero-width characters for alignment in Stremio.
    static func clean(_ text: String) -> String {
        // Filter scalars, not Characters: a zero-width joiner merges into the preceding grapheme.
        let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !invisible.contains($0) })
        return String(scalars)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
