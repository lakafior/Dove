import Foundation

/// What a music release's name says about its files: "[24Bit-192kHz] FLAC", "MP3 320", "WEB FLAC", "DSD64".
/// Indexers list no files, so the name is all there is.
public enum MusicFileFormat: String, Sendable, Hashable, CaseIterable, Comparable {
    /// 24-bit or more than 48 kHz, whatever the container.
    case hiRes
    case flac, alac, dsd, mp3, aac

    public var displayName: String {
        switch self {
        case .hiRes: "Hi-Res"
        case .flac: "FLAC"
        case .alac: "ALAC"
        case .dsd: "DSD"
        case .mp3: "MP3"
        case .aac: "AAC"
        }
    }

    /// Formats the name mentions, best first.
    public static func formats(in name: String) -> [MusicFileFormat] {
        let text = name.lowercased()
        let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        var found: Set<MusicFileFormat> = []
        if words.contains("flac") || words.contains("lossless") { found.insert(.flac) }
        if words.contains("alac") { found.insert(.alac) }
        if !words.isDisjoint(with: ["dsd", "dsd64", "dsd128", "dsd256", "dsf", "dff", "sacd"]) { found.insert(.dsd) }
        if !words.isDisjoint(with: ["mp3", "320kbps", "v0", "v2"]) || text.range(of: #"\bmp3\b|\b320 ?k"#, options: .regularExpression) != nil {
            found.insert(.mp3)
        }
        if !words.isDisjoint(with: ["aac", "m4a"]) { found.insert(.aac) }
        // "24Bit-192kHz", "24-96", "24 bit", "Hi-Res", "96kHz"
        let hiRes = #"\b24 ?-? ?bit|\bhi-?res\b|\b24 ?[-/] ?(88|96|176|192)|\b(88[.,]2|96|176[.,]4|192) ?khz"#
        if text.range(of: hiRes, options: .regularExpression) != nil { found.insert(.hiRes) }
        return found.sorted()
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
