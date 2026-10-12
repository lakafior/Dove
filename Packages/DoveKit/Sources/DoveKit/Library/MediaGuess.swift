import Foundation

/// What a library item probably is, read from its release name: title, year, movie or series, episode.
public struct MediaGuess: Sendable, Hashable, Codable {
    public var title: String
    public var year: Int?
    public var type: MediaType
    public var season: Int?
    public var episode: Int?
    /// For series: one or more episodes, a season, several seasons, or the complete series.
    public var scope: SeriesScope?

    /// Groups items of the same title regardless of episode or release: `severance|series`, `dune|2021|movie`.
    public var key: String {
        let base = MediaGuess.normalize(title)
        switch type {
        case .series: return "\(base)|series"
        case .movie: return "\(base)|\(year.map(String.init) ?? "")|movie"
        }
    }

    public init(
        title: String,
        year: Int? = nil,
        type: MediaType,
        season: Int? = nil,
        episode: Int? = nil,
        scope: SeriesScope? = nil
    ) {
        self.title = title
        self.year = year
        self.type = type
        self.season = season
        self.episode = episode
        self.scope = scope
    }

    /// Lowercased letters and digits only, `&` as "and": "Marvel's Agents of S.H.I.E.L.D." → "marvelsagentsofshield".
    public static func normalize(_ title: String) -> String {
        title.lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .folding(options: .diacriticInsensitive, locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

/// How much of a series a release holds.
public enum SeriesScope: Sendable, Hashable, Codable {
    case episodes(season: Int, [Int])
    case season(Int)
    case seasons(first: Int, last: Int)
    /// "Complete series" without a season range in the name.
    case complete

    /// "S02E05", "S02E01–E03", "Season 2", "Seasons 1–3", "Complete series".
    public var label: String {
        switch self {
        case .episodes(let season, let episodes):
            let first = episodes.first ?? 0
            let code = "S\(Self.two(season))E\(Self.two(first))"
            guard let last = episodes.last, last != first else { return code }
            return code + "–E\(Self.two(last))"
        case .season(let season): return "Season \(season)"
        case .seasons(let first, let last): return "Seasons \(first)–\(last)"
        case .complete: return "Complete series"
        }
    }

    public var isPack: Bool {
        if case .episodes = self { false } else { true }
    }

    private static func two(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
}

extension ReleaseParser {
    private static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "ts", "m2ts", "mov", "wmv", "webm", "iso"]

    /// Words that end the title part of a release name.
    private static let stopWords: Set<String> = [
        "2160p", "1440p", "1080p", "1080i", "720p", "576p", "480p", "4k", "uhd", "hd",
        "bluray", "blu", "bdrip", "brrip", "bdremux", "remux", "web", "webdl", "webrip", "hdtv", "dvdrip", "dvd",
        "hdr", "hdr10", "dv", "dovi", "sdr", "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "xvid",
        "multi", "pl", "plsub", "pldub", "lektor", "dubbed", "subbed", "ita", "eng", "ger", "fre", "spa", "pol",
        "proper", "repack", "complete", "internal", "imax", "extended", "unrated", "remastered", "hybrid", "uncut",
        "ddp", "ddp5", "dd5", "atmos", "truehd", "dts", "aac", "ac3", "eac3",
        "amzn", "nf", "dsnp", "hmax", "atvp", "itunes", "it",
    ]

    /// Reads the title, year and episode from a release or file name.
    public static func guess(_ name: String) -> MediaGuess {
        var base = name.trimmingCharacters(in: .whitespaces)
        let ext = (base as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) { base = (base as NSString).deletingPathExtension }
        // Leading "[Group]" tags and "www.site.org - " prefixes.
        base = base.replacingOccurrences(of: #"^(\[[^\]]*\]\s*)+"#, with: "", options: .regularExpression)
        base = base.replacingOccurrences(of: #"^www\.\S+\s*-\s*"#, with: "", options: [.regularExpression, .caseInsensitive])

        let spaced = base
            .replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\[\]\(\)\{\}]"#, with: " ", options: .regularExpression)
        let tokens = spaced.split(separator: " ").map(String.init)

        var titleTokens: [String] = []
        var year: Int?
        for (index, token) in tokens.enumerated() {
            let lower = token.lowercased()
            if token.count == 4, let value = Int(token), (1900...2099).contains(value) {
                // A year as the very first word is part of the title ("1917"); so is one followed by another
                // year ("Blade Runner 2049 2017").
                let next = index + 1 < tokens.count ? Int(tokens[index + 1]) : nil
                let nextIsYear = next.map { (1900...2099).contains($0) } ?? false
                if titleTokens.isEmpty || nextIsYear {
                    titleTokens.append(token)
                    continue
                }
                year = value
                break
            }
            if isEpisodeToken(lower) || stopWords.contains(lower.replacingOccurrences(of: "-", with: "")) || lower == "season" {
                break
            }
            titleTokens.append(token)
        }

        let lower = spaced.lowercased()
        let (seasons, episodes) = seasonsAndEpisodes(in: lower)
        var title = titleTokens.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–:,"))
        if title.isEmpty { title = base }
        let scope: SeriesScope? = if let season = seasons.first, !episodes.isEmpty {
            .episodes(season: season, episodes)
        } else if let first = seasons.first, let last = seasons.last, last > first {
            .seasons(first: first, last: last)
        } else if let season = seasons.first {
            .season(season)
        } else if lower.range(of: #"\bcomplete (series|seasons)\b|\b(series|seasons) complete\b"#, options: .regularExpression) != nil {
            .complete
        } else {
            nil
        }
        return MediaGuess(
            title: title,
            year: year,
            type: scope == nil ? .movie : .series,
            season: seasons.first,
            episode: episodes.first,
            scope: scope
        )
    }

    private static func isEpisodeToken(_ token: String) -> Bool {
        token.range(of: #"^s\d{1,2}(e\d{1,3})?(-?e?\d{1,3})?$|^\d{1,2}x\d{2,3}$|^s\d{1,2}-s?\d{1,2}$"#, options: .regularExpression) != nil
    }
}
