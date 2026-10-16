import Foundation

/// How good a release looks from its name: resolution, DV/HDR, source, and what plays badly on Apple TV.
/// Compares what the library holds with search results ("a better version"), using the same scales as
/// `SourceRanking`.
public struct ReleaseQuality: Sendable, Hashable, Codable {
    public var resolution: String?
    /// "BluRay REMUX", "WEB-DL"…
    public var source: String?
    /// "DV", "HDR10+" or "HDR".
    public var hdr: String?
    public var appleTVIssues: [String]

    public init(traits: StreamTraits) {
        resolution = traits.resolution
        source = traits.quality
        hdr = ["DV", "HDR10+", "HDR"].first { traits.visualTags.contains($0) }
        appleTVIssues = Self.appleTVWarnings(traits)
    }

    public init(name: String) {
        self.init(traits: ReleaseParser.parse(name))
    }

    /// A file inside a release: the file name's tags, completed by the release's (folders often carry them).
    public init(file: String, release: String) {
        self.init(traits: ReleaseParser.parse(file).merged(with: ReleaseParser.parse(release)))
    }

    /// Things that play badly through Infuse on Apple TV.
    public static func appleTVWarnings(_ traits: StreamTraits) -> [String] {
        var warnings: [String] = []
        if traits.encode == "AV1" { warnings.append("AV1: no hardware decoding on Apple TV") }
        if traits.audioTags.contains("TrueHD"), traits.audioTags.contains("Atmos"), !traits.audioTags.contains("DD+") {
            warnings.append("TrueHD Atmos: Apple TV drops the Atmos layer")
        }
        return warnings
    }

    /// "2160p DV BluRay REMUX", "720p HDTV"; nil when the name says nothing.
    public var label: String? {
        let parts = [resolution, hdr, source].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var resolutionRank: Int { SourceRanking.resolutionRank[resolution ?? ""] ?? 0 }
    var hdrRank: Int { SourceRanking.hdrRank(hdr.map { [$0] } ?? []) }
    var sourceRank: Int { SourceRanking.sourceRank[source ?? ""] ?? 0 }

    /// Why this is worth replacing, shortest first: low resolution, a poor source, AV1 (no hardware decoding on
    /// Apple TV). Empty when nothing is known to be wrong (an unknown resolution is not a reason). TrueHD Atmos is
    /// not one: it still plays as lossless 7.1, and nearly every remux has it.
    public var weaknesses: [String] {
        var reasons: [String] = []
        if resolution == "720p" || resolution == "480p" { reasons.append(resolution!) }
        if let source, ["CAM", "HDTV", "DVD"].contains(source) { reasons.append(source) }
        if appleTVIssues.contains(where: { $0.hasPrefix("AV1") }) { reasons.append("AV1") }
        return reasons
    }

    public var isWeak: Bool { !weaknesses.isEmpty }

    /// Clearly better than `base`: a higher resolution; or the same one without `base`'s Apple TV trouble;
    /// or the same one with better HDR, or (HDR equal) a better source. A cam is never an upgrade, and neither is
    /// a release with Apple TV trouble `base` does not have, or an unknown resolution.
    public func isUpgrade(over base: ReleaseQuality) -> Bool {
        if source == "CAM" || resolutionRank == 0 { return false }
        if resolutionRank != base.resolutionRank { return resolutionRank > base.resolutionRank && appleTVIssues.count <= base.appleTVIssues.count }
        if appleTVIssues.isEmpty != base.appleTVIssues.isEmpty { return appleTVIssues.isEmpty }
        if hdrRank != base.hdrRank { return hdrRank > base.hdrRank }
        return sourceRank > base.sourceRank
    }

    /// Worse first: Apple TV trouble, then resolution, HDR, source.
    static func worse(_ a: ReleaseQuality, _ b: ReleaseQuality) -> Bool {
        let ka = [a.appleTVIssues.isEmpty ? 1 : 0, a.resolutionRank, a.hdrRank, a.sourceRank]
        let kb = [b.appleTVIssues.isEmpty ? 1 : 0, b.resolutionRank, b.hdrRank, b.sourceRank]
        return ka.lexicographicallyPrecedes(kb)
    }
}
