import Foundation

/// "Recommended" order for a source list. Criteria, most important first:
/// 1. usable at all: a name Real-Debrid refuses is useless when Real-Debrid is the only debrid;
/// 2. plays well through Infuse on Apple TV (no AV1, no TrueHD-only Atmos);
/// 3. the ladder (`Tier`): ready (cached on one of the user's services, or Usenet), then uncached public
///    torrents, then uncached private ones (only a seeding service takes them, and they cost ratio);
/// 4. quality: resolution, DV/HDR, source, audio;
/// 5. not refused by Real-Debrid: with other debrids "Automatic" falls through after one quick failed try, so it
///    only breaks ties between equal releases; then size.
public struct SourceRanking: Sendable {
    /// The user's configured debrids, in priority order.
    public var debrids: [BackendID]

    public init(debrids: [BackendID] = []) {
        self.debrids = debrids
    }

    public func sorted(_ groups: [StreamGroup]) -> [StreamGroup] {
        groups
            .map { (group: $0, key: key(for: $0)) }
            .sorted { lhs, rhs in
                lhs.key != rhs.key ? lhs.key.lexicographicallyPrecedes(rhs.key, by: >) : (lhs.group.size ?? 0) > (rhs.group.size ?? 0)
            }
            .map(\.group)
    }

    /// Why a release is likely to fail on Real-Debrid, for the row. Nil when it does not matter.
    public func realDebridWarning(for group: StreamGroup) -> String? {
        guard refusedByRealDebrid(group) else { return nil }
        return onlyRealDebrid
            ? "Real-Debrid refuses this release name"
            : "Real-Debrid refuses this name; another service takes it"
    }

    // MARK: - Scoring

    func key(for group: StreamGroup) -> [Int] {
        let traits = group.traits
        let refused = refusedByRealDebrid(group)
        return [
            refused && onlyRealDebrid ? 0 : 1,
            group.appleTVWarnings.isEmpty ? 1 : 0,
            tier(for: group).rawValue,
            Self.resolutionRank[traits.resolution ?? ""] ?? 0,
            Self.hdrRank(traits.visualTags),
            Self.sourceRank[traits.quality ?? ""] ?? 0,
            Self.audioRank(traits.audioTags),
            refused ? 0 : 1,
        ]
    }

    /// How ready a release is, best last. Quality sorts within a rung.
    public enum Tier: Int, Sendable, Comparable {
        case uncachedPrivate, uncachedPublic, ready

        public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Usenet counts as ready on any service (nzbdav marks it ⚡, TorBox/Offcloud do not): it downloads at line speed,
    /// so a 2160p DV NZB should not sink below a cached 1080p torrent.
    public func tier(for group: StreamGroup) -> Tier {
        if group.sourceType == .usenet || cachedOnUserService(group) { return .ready }
        return group.isPrivate == true ? .uncachedPrivate : .uncachedPublic
    }

    private var onlyRealDebrid: Bool {
        debrids.contains(.realDebrid) && debrids.allSatisfy { $0 == .realDebrid || $0 == .nzbdav }
    }

    /// The release name matches Real-Debrid's filter and Real-Debrid is where it would go:
    /// no other configured service has it cached.
    private func refusedByRealDebrid(_ group: StreamGroup) -> Bool {
        guard group.kind != .usenet, debrids.contains(.realDebrid) else { return false }
        let names = [group.title, group.folderName].compactMap { $0 }
        guard names.contains(where: RealDebridNameFilter.isBlocked) else { return false }
        return !group.cachedBackends().contains { $0 != .realDebrid && debrids.contains($0) }
    }

    /// Cached where the user has an account. With no debrids known, any cache counts.
    private func cachedOnUserService(_ group: StreamGroup) -> Bool {
        let cached = group.cachedBackends()
        if debrids.isEmpty { return group.isCached }
        return cached.contains { debrids.contains($0) }
    }

    static let resolutionRank = ["2160p": 4, "1440p": 3, "1080p": 2, "720p": 1]
    static let sourceRank = [
        "BluRay REMUX": 6, "BluRay": 5, "WEB-DL": 4, "WEBRip": 3, "WEB": 3, "HDTV": 2, "DVD": 1, "CAM": -1,
    ]

    static func hdrRank(_ tags: [String]) -> Int {
        if tags.contains("DV") { return 3 }
        if tags.contains("HDR10+") { return 2 }
        return tags.contains("HDR") ? 1 : 0
    }

    private static func audioRank(_ tags: [String]) -> Int {
        if tags.contains("Atmos") { return 3 }
        if tags.contains("TrueHD") || tags.contains("DTS-HD") { return 2 }
        return tags.contains("DD+") || tags.contains("DTS") ? 1 : 0
    }
}
