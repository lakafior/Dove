import Foundation

/// One release, however many services offered it. Sources with the same info hash are merged,
/// so a row can say "cached on Offcloud and TorBox, not on Real-Debrid".
public struct StreamGroup: Identifiable, Sendable, Hashable {
    public let id: String
    /// In the order the addons ranked them; the first one represents the group.
    public var candidates: [StreamCandidate]
    /// Addon traits, completed from the file and folder names.
    public var traits: StreamTraits
    public var availability: [Availability]

    public struct Availability: Sendable, Hashable {
        /// As named by the addon: `realdebrid`, `torbox`, `offcloud`, `nzbdav`, `easynews`…
        public var service: String
        public var cached: Bool?
        public var backend: BackendID? { BackendID(service: service) }

        public var displayName: String {
            backend?.displayName ?? service.capitalized
        }
    }

    public var primary: StreamCandidate { candidates[0] }
    public var title: String { primary.title }
    public var folderName: String? { candidates.lazy.compactMap(\.folderName).first }
    public var size: Int64? { candidates.lazy.compactMap(\.size).first }
    public var folderSize: Int64? { candidates.lazy.compactMap(\.folderSize).first }
    public var infoHash: String? { candidates.lazy.compactMap(\.infoHash).first }
    public var kind: StreamCandidate.Kind { primary.kind }
    /// Newznab category from Dove's own indexers (Search › Other shows the kind).
    public var category: Int? { candidates.lazy.compactMap(\.category).first }
    /// The most seeders any tracker reported.
    public var seeders: Int? { candidates.compactMap(\.seeders).max() }
    public var sourceType: SourceType { primary.sourceType }
    /// True when any tracker that has it is private, false when they all said public, nil when nobody said.
    public var isPrivate: Bool? {
        let known = candidates.compactMap(\.isPrivate)
        return known.isEmpty ? nil : known.contains(true)
    }
    /// The newest upload date anyone gave.
    public var published: Date? { candidates.compactMap(\.published).max() }
    /// Each distinct path it was found by ("AIOStreams › Torrentio › 1337x"), in candidate order.
    public var origins: [[String]] {
        var seen = Set<[String]>()
        return candidates.map(\.origin).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    /// Who answered Dove (AIOStreams, an addon, an indexer) and the addons inside AIOStreams.
    public var providers: [String] {
        unique(candidates.flatMap { [$0.addon ?? $0.provider].compactMap { $0 } })
    }
    /// Trackers and Usenet indexers behind it. AIOStreams lists several as `uindex,zilean`.
    public var trackers: [String] {
        unique(candidates.compactMap(\.tracker).flatMap {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        })
    }

    private func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Link to play: a cached one if any service has it, otherwise the first.
    public var playURL: URL? {
        candidates.first { $0.cached == true && $0.url != nil }?.url ?? candidates.lazy.compactMap(\.url).first
    }

    /// An indexer's `.torrent` first (see `StreamCandidate.librarySource`), then whatever the first candidate has.
    public var librarySource: Source? {
        candidates.lazy.compactMap { $0.torrentURL.map(Source.torrentURL) }.first
            ?? candidates.lazy.compactMap(\.librarySource).first
    }

    /// Dove's own indexers that found this release (their names are the candidates' labels).
    public var indexers: [String] {
        var seen = Set<String>()
        return candidates.filter { $0.id.hasPrefix("newznab:") }.map(\.label).filter { seen.insert($0).inserted }
    }

    public var isCached: Bool {
        availability.contains { $0.cached == true }
    }

    /// Debrid backends that already have it cached, in the order given.
    public func cachedBackends() -> [BackendID] {
        availability.filter { $0.cached == true }.compactMap(\.backend)
    }

    public var isPack: Bool {
        candidates.contains(where: \.isPack) || !packSeasons.isEmpty
    }

    /// Seasons the torrent folder holds as whole seasons; empty for single episodes and movies.
    public var packSeasons: [Int] {
        if !traits.folderSeasons.isEmpty { return traits.folderSeasons }
        return traits.seasonPack ? traits.seasons : []
    }

    public func isSeasonPack(_ season: Int) -> Bool {
        packSeasons == [season]
    }

    /// Several seasons, or a "Complete" folder with no season number.
    public var isSeriesPack: Bool {
        if packSeasons.count > 1 { return true }
        guard let folderName else { return false }
        return folderName.localizedCaseInsensitiveContains("complete") && ReleaseParser.parse(folderName).seasons.isEmpty
    }

    /// Things that play badly through Infuse on Apple TV.
    public var appleTVWarnings: [String] {
        var warnings: [String] = []
        if traits.encode == "AV1" { warnings.append("AV1: no hardware decoding on Apple TV") }
        if traits.audioTags.contains("TrueHD"), traits.audioTags.contains("Atmos"), !traits.audioTags.contains("DD+") {
            warnings.append("TrueHD Atmos: Apple TV drops the Atmos layer")
        }
        return warnings
    }

    // MARK: - Grouping

    /// Merges candidates with the same info hash, keeping the addons' order. NZBs from Dove's own indexers
    /// have no hash: the same release name from several indexers becomes one row listing each indexer.
    public static func group(_ candidates: [StreamCandidate]) -> [StreamGroup] {
        var groups: [StreamGroup] = []
        var indexByKey: [String: Int] = [:]
        for candidate in candidates {
            let key = candidate.infoHash?.lowercased()
                ?? (candidate.id.hasPrefix("newznab:") ? "nzb:" + MediaGuess.normalize(candidate.title) : candidate.id)
            if let index = indexByKey[key] {
                groups[index].add(candidate)
            } else {
                indexByKey[key] = groups.count
                groups.append(StreamGroup(first: candidate, id: key))
            }
        }
        return groups
    }

    init(first: StreamCandidate, id: String) {
        self.id = id
        candidates = [first]
        traits = Self.traits(of: first)
        availability = []
        record(first)
    }

    private mutating func add(_ candidate: StreamCandidate) {
        candidates.append(candidate)
        traits = traits.merged(with: Self.traits(of: candidate))
        record(candidate)
    }

    private mutating func record(_ candidate: StreamCandidate) {
        guard let service = candidate.service else { return }
        record(service: service, cached: candidate.cached)
    }

    /// Adds what a service said; `true` always wins, a known `false` replaces "unknown".
    mutating func record(service: String, cached: Bool?) {
        if let index = availability.firstIndex(where: { $0.service.lowercased() == service.lowercased() }) {
            if cached == true || availability[index].cached == nil { availability[index].cached = cached ?? availability[index].cached }
        } else {
            availability.append(Availability(service: service, cached: cached))
        }
    }

    private static func traits(of candidate: StreamCandidate) -> StreamTraits {
        var traits = (candidate.traits ?? StreamTraits()).merged(with: ReleaseParser.parse(candidate.title))
        if let folder = candidate.folderName {
            let folderTraits = ReleaseParser.parse(folder)
            traits = traits.merged(with: folderTraits)
            if folderTraits.seasonPack, traits.folderSeasons.isEmpty { traits.folderSeasons = folderTraits.seasons }
        }
        return traits
    }
}

/// Which releases to show when the user asks for more than one episode.
public enum PackScope: Sendable, Hashable {
    case season(Int)
    case series

    public func matches(_ group: StreamGroup) -> Bool {
        guard group.librarySource != nil || group.playURL != nil else { return false }
        switch self {
        case .season(let season): return group.isSeasonPack(season)
        case .series: return group.isSeriesPack
        }
    }
}

extension BackendID {
    /// Maps the service names used by Stremio addons (AIOStreams, StremThru…) to Dove's backends.
    public init?(service: String) {
        switch service.lowercased().replacingOccurrences(of: "-", with: "") {
        case "realdebrid", "rd": self = .realDebrid
        case "torbox", "tb": self = .torBox
        case "offcloud", "oc": self = .offcloud
        case "debridlink", "dl": self = .debridLink
        case "premiumize", "pm": self = .premiumize
        case "alldebrid", "ad": self = .allDebrid
        case "nzbdav", "nd": self = .nzbdav
        default: return nil
        }
    }
}
