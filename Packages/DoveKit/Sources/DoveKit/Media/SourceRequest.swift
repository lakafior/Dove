import Foundation

/// A source list narrowed by a sentence ("2160p DV without Atmos under 20 GB, Polish audio"): what the words ask for,
/// mapped onto the filter's dimensions (by the on-device model in the app) and checked here against the values the
/// list really has. It goes beyond `SourceFilter` (things to avoid, a size range) and lives for the session only: it
/// sits on top of the saved filter until cleared, so a one-off wish never changes the user's filter.
public struct SourceRequest: Equatable, Sendable {
    public typealias Dimension = SourceFilter.Dimension

    /// The dimensions words can reach; tracker and provider names are the user's own and better picked by hand.
    public static let dimensions: [Dimension] = [.resolution, .quality, .encode, .video, .audio, .language, .type]

    /// What the user typed, shown on the chip that clears it.
    public var text: String
    /// Alternatives within a dimension, dimensions combined, like `SourceFilter`.
    public var wanted: [Dimension: Set<String>] = [:]
    /// A release with any of these is left out.
    public var avoided: [Dimension: Set<String>] = [:]
    public var maxSize: Int64?
    public var minSize: Int64?
    public var cachedOnly = false
    public var appleTVFriendly = false
    public var sort: SourceFilter.Sort?

    public init(text: String) {
        self.text = text
    }

    /// From the model's answer: values it may have phrased its own way ("4K", "Dolby Vision", "Polish") are mapped
    /// to the list's own; anything the list does not know, or the words do not mention, is dropped rather than
    /// guessed (a small model reads "Polish audio" as PL and, unasked, AAC).
    public init(
        text: String,
        wanted: [Dimension: [String]],
        avoided: [Dimension: [String]],
        maxSizeGB: Double?,
        minSizeGB: Double?,
        cachedOnly: Bool,
        appleTVFriendly: Bool,
        sort: String?,
        in groups: [StreamGroup]
    ) {
        self.text = text
        let vocabulary = Self.vocabulary(for: groups)
        for (dimension, values) in wanted {
            let known = Self.resolve(values, in: dimension, vocabulary: vocabulary).filter { Self.mentions(text, $0, in: dimension) }
            if !known.isEmpty { self.wanted[dimension] = known }
        }
        for (dimension, values) in avoided {
            let known = Self.resolve(values, in: dimension, vocabulary: vocabulary).filter { Self.mentions(text, $0, in: dimension) }
            if !known.isEmpty { self.avoided[dimension] = known }
        }
        // The model sometimes drops a language it was given ("Polish audio"): a language the words name and the list
        // has is wanted unless the model put it among the things to avoid.
        for (name, code) in LanguageName.codes where vocabulary[.language]?.contains(code) == true
            && Self.mentionsAny(text, [name]) && self.avoided[.language]?.contains(code) != true {
            self.wanted[.language, default: []].insert(code)
        }
        let hasNumber = text.contains { $0.isNumber }
        maxSize = maxSizeGB.flatMap { $0 > 0 && hasNumber ? Int64($0 * 1_000_000_000) : nil }
        minSize = minSizeGB.flatMap { $0 > 0 && hasNumber ? Int64($0 * 1_000_000_000) : nil }
        self.cachedOnly = cachedOnly && Self.mentionsAny(text, ["cached", "cache", "instant", "ready"])
        self.appleTVFriendly = appleTVFriendly && Self.mentionsAny(text, ["apple tv", "appletv", "atv"])
        self.sort = sort.flatMap(Self.sort(named:)).flatMap { sort in
            Self.mentionsAny(text, Self.sortWords[sort] ?? []) ? sort : nil
        }
    }

    public var isEmpty: Bool {
        wanted.isEmpty && avoided.isEmpty && maxSize == nil && minSize == nil && !cachedOnly && !appleTVFriendly && sort == nil
    }

    public func matches(_ group: StreamGroup) -> Bool {
        if appleTVFriendly, !group.appleTVWarnings.isEmpty { return false }
        if cachedOnly, !group.availability.contains(where: { $0.cached == true }) { return false }
        // A size bound wants a known size.
        if let maxSize, (group.size ?? .max) > maxSize { return false }
        if let minSize, (group.size ?? 0) < minSize { return false }
        for (dimension, values) in wanted where SourceFilter.values(of: dimension, in: group).isDisjoint(with: values) {
            return false
        }
        for (dimension, values) in avoided where !SourceFilter.values(of: dimension, in: group).isDisjoint(with: values) {
            return false
        }
        return true
    }

    /// Keeps the matching groups in the order they came in (the saved filter's), unless the words asked for an order.
    public func apply(to groups: [StreamGroup], ranking: SourceRanking = SourceRanking()) -> [StreamGroup] {
        let kept = groups.filter(matches)
        guard let sort else { return kept }
        var sorter = SourceFilter()
        sorter.sort = sort
        return sorter.apply(to: kept, ranking: ranking)
    }

    /// What the request does, short, for the chip under the words: "2160p · DV · PL · no Atmos · ≤ 20 GB".
    public var summary: String {
        var parts: [String] = []
        for dimension in Self.dimensions {
            if let values = wanted[dimension], !values.isEmpty { parts.append(Self.ordered(values, in: dimension).joined(separator: "/")) }
        }
        for dimension in Self.dimensions {
            if let values = avoided[dimension], !values.isEmpty { parts.append("no " + Self.ordered(values, in: dimension).joined(separator: "/")) }
        }
        if let minSize { parts.append("≥ \(minSize.formatted(.byteCount(style: .file)))") }
        if let maxSize { parts.append("≤ \(maxSize.formatted(.byteCount(style: .file)))") }
        if cachedOnly { parts.append("cached") }
        if appleTVFriendly { parts.append("Apple TV friendly") }
        if let sort { parts.append(sort.title) }
        return parts.joined(separator: " · ")
    }

    private static func ordered(_ values: Set<String>, in dimension: Dimension) -> [String] {
        let order = SourceFilter.preferredOrder[dimension] ?? []
        return values.sorted { (order.firstIndex(of: $0) ?? .max, $0) < (order.firstIndex(of: $1) ?? .max, $1) }
    }

    /// The names the model uses for the dimensions (plain words, not the filter's titles).
    public static let dimensionNames: [String: Dimension] = [
        "resolution": .resolution, "source": .quality, "codec": .encode, "hdr": .video,
        "audio": .audio, "language": .language, "type": .type,
    ]

    /// Criteria as the model gives them (dimension name, value), grouped by dimension; unknown names dropped.
    public static func grouped(_ criteria: [(dimension: String, value: String)]) -> [Dimension: [String]] {
        var result: [Dimension: [String]] = [:]
        for criterion in criteria {
            guard let dimension = dimensionNames[criterion.dimension.lowercased()] else { continue }
            result[dimension, default: []].append(criterion.value)
        }
        return result
    }

    // MARK: - Vocabulary

    /// Per dimension, the values this list has, then the usual ones: what the model is told it may use.
    public static func vocabulary(for groups: [StreamGroup]) -> [Dimension: [String]] {
        var result: [Dimension: [String]] = [:]
        for dimension in dimensions {
            var values = SourceFilter.options(for: dimension, in: groups).map(\.value).filter { $0 != "Unknown" }
            for value in SourceFilter.preferredOrder[dimension] ?? [] where value != "Unknown" && !values.contains(value) {
                values.append(value)
            }
            result[dimension] = values
        }
        return result
    }

    /// Spellings people (and the model) use for the list's values.
    static let synonyms: [Dimension: [String: String]] = [
        .resolution: ["4k": "2160p", "uhd": "2160p", "2160": "2160p", "1440": "1440p", "2k": "1440p", "qhd": "1440p",
                      "1080": "1080p", "fhd": "1080p", "full hd": "1080p", "720": "720p", "hd": "720p", "480": "480p", "sd": "480p"],
        .quality: ["remux": "BluRay REMUX", "blu-ray remux": "BluRay REMUX", "bluray": "BluRay", "blu-ray": "BluRay",
                   "bdrip": "BluRay", "web dl": "WEB-DL", "webdl": "WEB-DL", "web rip": "WEBRip", "dvdrip": "DVD", "cam": "CAM"],
        .encode: ["h.265": "HEVC", "h265": "HEVC", "x265": "HEVC", "h.264": "AVC", "h264": "AVC", "x264": "AVC"],
        .video: ["dolby vision": "DV", "dovi": "DV", "hdr10": "HDR", "hdr10plus": "HDR10+", "no hdr": "SDR"],
        .audio: ["dolby atmos": "Atmos", "dolby truehd": "TrueHD", "true hd": "TrueHD", "dts-hd ma": "DTS-HD",
                 "dts hd": "DTS-HD", "ddp": "DD+", "eac3": "DD+", "e-ac-3": "DD+", "dolby digital plus": "DD+",
                 "ac3": "DD", "dolby digital": "DD"],
        .type: ["torrents": "Torrent", "nzb": "Usenet", "newsgroups": "Usenet", "direct": "Web"],
    ]

    static func resolve(_ values: [String], in dimension: Dimension, vocabulary: [Dimension: [String]]) -> Set<String> {
        let known = vocabulary[dimension] ?? []
        var result: Set<String> = []
        for raw in values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let lowered = value.lowercased()
            var candidates = [value]
            if let synonym = synonyms[dimension]?[lowered] { candidates.append(synonym) }
            if dimension == .language { candidates.append(LanguageName.code(value)) }
            if let match = candidates.lazy.compactMap({ candidate in
                known.first { $0.caseInsensitiveCompare(candidate) == .orderedSame }
            }).first {
                result.insert(match)
            }
        }
        return result
    }

    // MARK: - Evidence

    /// Whether the words name this value: itself ("2160p", "Atmos"), a synonym ("4K"), or for languages a name
    /// that maps to the code ("Polish" → PL). Whole words only, so "dv" is not found in "advanced".
    static func mentions(_ text: String, _ value: String, in dimension: Dimension) -> Bool {
        var phrases = [value]
        phrases += (synonyms[dimension] ?? [:]).filter { $0.value == value }.map(\.key)
        if dimension == .language {
            phrases += LanguageName.codes.filter { $0.value == value }.map(\.key)
        }
        if dimension == .video, value == "SDR" { phrases += ["sdr", "no hdr", "without hdr"] }
        return mentionsAny(text, phrases)
    }

    static func mentionsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { phrase in
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            return text.range(of: "(?<![A-Za-z0-9])\(escaped)(?![A-Za-z0-9])", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static let sortWords: [SourceFilter.Sort: [String]] = [
        .sizeDescending: ["largest", "biggest", "large", "big"],
        .sizeAscending: ["smallest", "small", "lightest"],
        .seeders: ["seeders", "seeds", "seeded", "popular"],
        .newest: ["newest", "latest", "recent", "new"],
        .recommended: ["recommended", "best"],
    ]

    static func sort(named name: String) -> SourceFilter.Sort? {
        switch name.lowercased().trimmingCharacters(in: .whitespaces) {
        case "largest", "biggest", "size", "largest first": .sizeDescending
        case "smallest", "smallest first": .sizeAscending
        case "seeders", "most seeders", "popular": .seeders
        case "newest", "newest first", "latest": .newest
        case "recommended", "best": .recommended
        default: SourceFilter.Sort(rawValue: name)
        }
    }
}
