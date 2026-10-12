import Foundation

/// What the user wants to see in a source list. Values within one dimension are alternatives (OR),
/// dimensions combine (AND): "2160p or 1080p" and "DV" and "PL".
public struct SourceFilter: Codable, Equatable, Sendable {
    public enum Dimension: String, Codable, CaseIterable, Sendable {
        case resolution, quality, encode, video, audio, language, cached

        public var title: String {
            switch self {
            case .resolution: "Resolution"
            case .quality: "Source"
            case .encode: "Codec"
            case .video: "HDR"
            case .audio: "Audio"
            case .language: "Language"
            case .cached: "Cached on"
            }
        }
    }

    public enum Sort: String, Codable, CaseIterable, Sendable {
        /// As the addons ranked them (AIOStreams applies your sorting).
        case addon
        case sizeDescending
        case sizeAscending

        public var title: String {
            switch self {
            case .addon: "Addon order"
            case .sizeDescending: "Largest first"
            case .sizeAscending: "Smallest first"
            }
        }
    }

    public var selected: [Dimension: Set<String>] = [:]
    /// Hide releases that play badly through Infuse on Apple TV (AV1, TrueHD Atmos).
    public var appleTVFriendly = false
    public var sort: Sort = .sizeDescending

    public init() {}

    public var isActive: Bool {
        appleTVFriendly || selected.values.contains { !$0.isEmpty }
    }

    public var activeCount: Int {
        selected.values.filter { !$0.isEmpty }.count + (appleTVFriendly ? 1 : 0)
    }

    public mutating func toggle(_ value: String, in dimension: Dimension) {
        var values = selected[dimension] ?? []
        if values.contains(value) { values.remove(value) } else { values.insert(value) }
        selected[dimension] = values
    }

    public func isSelected(_ value: String, in dimension: Dimension) -> Bool {
        selected[dimension]?.contains(value) == true
    }

    public mutating func reset() {
        selected = [:]
        appleTVFriendly = false
    }

    // MARK: - Applying

    public func matches(_ group: StreamGroup) -> Bool {
        if appleTVFriendly && !group.appleTVWarnings.isEmpty { return false }
        for (dimension, wanted) in selected where !wanted.isEmpty {
            if Self.values(of: dimension, in: group).isDisjoint(with: wanted) { return false }
        }
        return true
    }

    public func apply(to groups: [StreamGroup]) -> [StreamGroup] {
        let kept = groups.filter(matches)
        switch sort {
        case .addon: return kept
        case .sizeDescending: return kept.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        case .sizeAscending: return kept.sorted { ($0.size ?? .max) < ($1.size ?? .max) }
        }
    }

    /// The values a dimension can take in these groups, in a sensible order, with how many groups have each.
    public static func options(for dimension: Dimension, in groups: [StreamGroup]) -> [(value: String, count: Int)] {
        var counts: [String: Int] = [:]
        for group in groups {
            for value in values(of: dimension, in: group) { counts[value, default: 0] += 1 }
        }
        let preferred = preferredOrder[dimension] ?? []
        return counts
            .sorted { lhs, rhs in
                let l = preferred.firstIndex(of: lhs.key) ?? Int.max
                let r = preferred.firstIndex(of: rhs.key) ?? Int.max
                return l != r ? l < r : (lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key)
            }
            .map { ($0.key, $0.value) }
    }

    static func values(of dimension: Dimension, in group: StreamGroup) -> Set<String> {
        let traits = group.traits
        switch dimension {
        case .resolution:
            return traits.resolution.map { [$0] } ?? ["Unknown"]
        case .quality:
            return traits.quality.map { [$0] } ?? ["Unknown"]
        case .encode:
            return traits.encode.map { [$0] } ?? ["Unknown"]
        case .video:
            let hdr = Set(traits.visualTags.filter { ["DV", "HDR10+", "HDR"].contains($0) })
            return hdr.isEmpty ? ["SDR"] : hdr
        case .audio:
            return Set(traits.audioTags)
        case .language:
            let languages = Set(traits.languages.map(LanguageName.code))
            return languages.isEmpty ? ["Unknown"] : languages
        case .cached:
            return Set(group.availability.filter { $0.cached == true }.map(\.displayName))
        }
    }

    private static let preferredOrder: [Dimension: [String]] = [
        .resolution: ["2160p", "1440p", "1080p", "720p", "480p", "Unknown"],
        .quality: ["BluRay REMUX", "BluRay", "WEB-DL", "WEBRip", "WEB", "HDTV", "DVD", "CAM", "Unknown"],
        .encode: ["HEVC", "AVC", "AV1", "XviD", "Unknown"],
        .video: ["DV", "HDR10+", "HDR", "SDR"],
        .audio: ["Atmos", "TrueHD", "DTS-HD", "DD+", "DTS", "DD", "AAC", "FLAC"],
        .language: ["PL", "EN", "MULTi"],
    ]

    // MARK: - Codable (dictionary keyed by enum)

    enum CodingKeys: String, CodingKey { case selected, appleTVFriendly, sort }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: Set<String>].self, forKey: .selected) ?? [:]
        selected = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in Dimension(rawValue: key).map { ($0, value) } })
        appleTVFriendly = try c.decodeIfPresent(Bool.self, forKey: .appleTVFriendly) ?? false
        sort = try c.decodeIfPresent(Sort.self, forKey: .sort) ?? .sizeDescending
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: selected.map { ($0.key.rawValue, $0.value) }), forKey: .selected)
        try c.encode(appleTVFriendly, forKey: .appleTVFriendly)
        try c.encode(sort, forKey: .sort)
    }
}

/// AIOStreams names languages ("Polish"), the release parser uses codes ("PL"). Filters use codes.
public enum LanguageName {
    static let codes: [String: String] = [
        "polish": "PL", "english": "EN", "german": "DE", "french": "FR", "italian": "IT", "spanish": "ES",
        "latino": "ES", "portuguese": "PT", "russian": "RU", "ukrainian": "UK", "czech": "CZ", "japanese": "JA",
        "korean": "KO", "chinese": "ZH", "hindi": "HI", "dutch": "NL", "swedish": "SV", "turkish": "TR",
        "multi": "MULTi", "dual audio": "MULTi", "dubbed": "Dub",
    ]

    public static func code(_ name: String) -> String {
        codes[name.lowercased()] ?? name
    }
}
