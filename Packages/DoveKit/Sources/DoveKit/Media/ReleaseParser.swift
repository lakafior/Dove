import Foundation

/// Reads scene-style release names (`Show.S01E02.2160p.WEB-DL.DDP5.1.Atmos.DV.HEVC-GRP`) into `StreamTraits`.
/// Used when an addon gives only a file name (AIOStreams' Search API parses for us), and later for library matching.
public enum ReleaseParser {
    public static func parse(_ name: String) -> StreamTraits {
        let text = normalized(name)
        var traits = StreamTraits()
        traits.resolution = resolution(in: text)
        traits.quality = quality(in: text)
        traits.encode = encode(in: text)
        traits.visualTags = visualTags(in: text)
        traits.audioTags = audioTags(in: text)
        traits.languages = languages(in: text)
        traits.releaseGroup = releaseGroup(in: name)
        let (seasons, episodes) = seasonsAndEpisodes(in: text)
        traits.seasons = seasons
        traits.episodes = episodes
        traits.seasonPack = !seasons.isEmpty && episodes.isEmpty
        traits.folderSeasons = traits.seasonPack ? seasons : []
        return traits
    }

    // MARK: - Fields

    private static func resolution(in text: String) -> String? {
        if matches(text, #"\b(2160p|4k|uhd)\b"#) { return "2160p" }
        if matches(text, #"\b1440p\b"#) { return "1440p" }
        if matches(text, #"\b1080[pi]\b"#) { return "1080p" }
        if matches(text, #"\b720p\b"#) { return "720p" }
        if matches(text, #"\b(576|480)p\b"#) { return "480p" }
        return nil
    }

    private static func quality(in text: String) -> String? {
        let remux = matches(text, #"\b(bd)?remux\b"#)
        if remux { return "BluRay REMUX" }
        if matches(text, #"\b(blu[ -]?ray|bd[ -]?rip|br[ -]?rip|bd)\b"#) { return "BluRay" }
        if matches(text, #"\bweb[ -]?dl\b"#) { return "WEB-DL" }
        if matches(text, #"\bweb[ -]?rip\b"#) { return "WEBRip" }
        if matches(text, #"\bweb\b"#) { return "WEB" }
        if matches(text, #"\bhdtv\b"#) { return "HDTV" }
        if matches(text, #"\bdvd[ -]?rip\b|\bdvd\b"#) { return "DVD" }
        if matches(text, #"\b(cam|hdcam|ts|telesync)\b"#) { return "CAM" }
        return nil
    }

    private static func encode(in text: String) -> String? {
        if matches(text, #"\bav1\b"#) { return "AV1" }
        if matches(text, #"\b(hevc|x265|h ?265)\b"#) { return "HEVC" }
        if matches(text, #"\b(avc|x264|h ?264)\b"#) { return "AVC" }
        if matches(text, #"\bxvid\b"#) { return "XviD" }
        return nil
    }

    private static func visualTags(in text: String) -> [String] {
        var tags: [String] = []
        if matches(text, #"\b(dv|dovi|dolby ?vision)\b"#) { tags.append("DV") }
        // `\b` does not work after "+": it sits between two non-word characters.
        if matches(text, #"\bhdr10(\+|p\b|plus\b)"#) {
            tags.append("HDR10+")
        } else if matches(text, #"\bhdr(10)?\b"#) {
            tags.append("HDR")
        }
        if matches(text, #"\b10 ?bit\b"#) { tags.append("10bit") }
        if matches(text, #"\bsdr\b"#) { tags.append("SDR") }
        return tags
    }

    private static func audioTags(in text: String) -> [String] {
        var tags: [String] = []
        if matches(text, #"\batmos\b"#) { tags.append("Atmos") }
        if matches(text, #"\btrue ?hd\b"#) { tags.append("TrueHD") }
        if matches(text, #"\bdts ?(hd ?)?ma\b|\bdts ?x\b"#) {
            tags.append("DTS-HD")
        } else if matches(text, #"\bdts\b"#) {
            tags.append("DTS")
        }
        if matches(text, #"\b(ddp|dd\+|eac3|e ac 3)"#) {
            tags.append("DD+")
        } else if matches(text, #"\b(dd|ac3|dolby digital)( ?[257] ?[01])?\b"#) {
            tags.append("DD")
        }
        if matches(text, #"\baac\b"#) { tags.append("AAC") }
        if matches(text, #"\bflac\b"#) { tags.append("FLAC") }
        return tags
    }

    /// Languages that matter for choosing a release here. Polish variants first.
    private static func languages(in text: String) -> [String] {
        var languages: [String] = []
        if matches(text, #"\b(pl|pol|polish|plsub|pldub|lektor|dubbing pl|napisy)\b"#) { languages.append("PL") }
        if matches(text, #"\bmulti\b"#) { languages.append("MULTi") }
        if matches(text, #"\b(ita|italian)\b"#) { languages.append("IT") }
        if matches(text, #"\b(ger|german|deutsch)\b"#) { languages.append("DE") }
        if matches(text, #"\b(fre|french|vff|vf2|truefrench)\b"#) { languages.append("FR") }
        if matches(text, #"\b(spa|spanish|castellano)\b"#) { languages.append("ES") }
        return languages
    }

    private static func releaseGroup(in name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        guard let dash = base.lastIndex(of: "-") else { return nil }
        let group = base[base.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        guard !group.isEmpty, group.count <= 20, !group.contains(" "), !group.contains(".") else { return nil }
        return group
    }

    /// `S01E02`, `S01E01-E03`, `1x02`, `S01`, `S01-S03`, `Season 2`, `Complete`.
    static func seasonsAndEpisodes(in text: String) -> (seasons: [Int], episodes: [Int]) {
        if let match = firstMatch(text, #"\bs(\d{1,2}) ?e(\d{1,3})(?: ?(?:e|-|- ?e)(\d{1,3}))?\b"#) {
            let season = match[1].flatMap { Int($0) } ?? 0
            let first = match[2].flatMap { Int($0) } ?? 0
            let last = match[3].flatMap { Int($0) } ?? first
            return ([season], Array(first...max(first, last)))
        }
        if let match = firstMatch(text, #"\b(\d{1,2})x(\d{2,3})\b"#) {
            return ([match[1].flatMap { Int($0) } ?? 0], [match[2].flatMap { Int($0) } ?? 0])
        }
        if let match = firstMatch(text, #"\bs(\d{1,2}) ?- ?s?(\d{1,2})\b"#),
           let first = match[1].flatMap({ Int($0) }), let last = match[2].flatMap({ Int($0) }), last >= first {
            return (Array(first...last), [])
        }
        if let match = firstMatch(text, #"\b(?:s|season ?)(\d{1,2})\b"#), let season = match[1].flatMap({ Int($0) }) {
            return ([season], [])
        }
        return ([], [])
    }

    // MARK: - Helpers

    /// Lowercased, with dots and underscores as spaces, so `\b` works on scene names.
    private static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}
