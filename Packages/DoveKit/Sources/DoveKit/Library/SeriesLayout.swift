import Foundation

/// A video file of a series placed on its episode: a file inside a pack, or a single-episode item.
public struct EpisodeFile: Identifiable, Sendable, Hashable {
    public let item: ShelfItem
    /// Nil for a single-episode item whose service lists it without files (Real-Debrid, Offcloud):
    /// the file is looked up when it is played.
    public let file: LibraryFile?

    public init(item: ShelfItem, file: LibraryFile?) {
        self.item = item
        self.file = file
    }

    public var id: String { "\(item.id)#\(file?.id ?? "")" }
    public var name: String { file?.name ?? item.item.name }
    public var size: Int64? { file?.size ?? item.item.size }
    public var isReady: Bool { item.item.status == .ready }
    /// "2160p", "1080p"… from the file name, else the release name.
    public var resolution: String? { ReleaseParser.parse(name).resolution ?? ReleaseParser.parse(item.item.name).resolution }
}

/// One episode with what the library holds of it; `files` is empty for an aired episode the library lacks.
public struct LibraryEpisode: Identifiable, Sendable, Hashable {
    public let season: Int
    public let number: Int
    /// From the metadata (title, air date); nil without a match.
    public var info: Episode?
    /// Preferred first: ready, then higher resolution, then larger.
    public var files: [EpisodeFile]

    public var id: String { "\(season)x\(number)" }
    public var code: String { SeriesScope.episodes(season: season, [number]).label }
    public var isAvailable: Bool { !files.isEmpty }
}

public struct LibrarySeason: Identifiable, Sendable, Hashable {
    public let number: Int
    public var episodes: [LibraryEpisode]

    public var id: Int { number }
    public var title: String { number == 0 ? "Specials" : "Season \(number)" }
    public var available: [LibraryEpisode] { episodes.filter(\.isAvailable) }

    /// "All 24 episodes", "Missing E04, E07 · 22 of 24", or "Not in your library".
    public var summary: String {
        let have = available.count
        if have == 0 { return "Not in your library" }
        let missing = episodes.filter { !$0.isAvailable }
        if missing.isEmpty { return "All \(have) episode\(have == 1 ? "" : "s")" }
        let shown = missing.prefix(4).map { "E" + ($0.number < 10 ? "0\($0.number)" : String($0.number)) }.joined(separator: ", ")
        let more = missing.count > 4 ? " +\(missing.count - 4)" : ""
        return "Missing \(shown)\(more) · \(have) of \(episodes.count)"
    }
}

/// A series' library items laid out as seasons and episodes: every video file is placed on the episode it
/// holds (scene codes, `1x02`, or a "Season 1" folder with "01 - Pilot.mkv"), merged with the metadata's
/// episode list so missing episodes show too.
public struct SeriesLayout: Sendable, Hashable {
    public var seasons: [LibrarySeason]
    /// Video files Dove could not place on an episode; they stay reachable from their release.
    public var unplaced: [EpisodeFile]

    /// - Parameters:
    ///   - files: files of items whose service lists them without files (Real-Debrid, Offcloud), loaded separately.
    ///   - detail: the series' metadata; aired episodes without a file show as missing. Specials only when held.
    public init(items: [ShelfItem], files: [ShelfItem.ID: [LibraryFile]] = [:], detail: MediaDetail? = nil, now: Date = .now) {
        var placed: [[Int]: [EpisodeFile]] = [:]
        var unplaced: [EpisodeFile] = []
        for item in items {
            let itemFiles = (item.item.files.isEmpty ? files[item.id] ?? [] : item.item.files)
                .filter { FileKind.isVideo($0.name) && !FileKind.isSample($0.name) }
            // A single-episode release: its one video (or the item itself when its files are not listed).
            if case .episodes(let season, let numbers) = item.guess.scope, itemFiles.count <= 1 {
                let file = EpisodeFile(item: item, file: itemFiles.first)
                for number in numbers { placed[[season, number], default: []].append(file) }
                continue
            }
            for file in itemFiles {
                let entry = EpisodeFile(item: item, file: file)
                guard let located = Self.locate(file.name, in: item.guess) else {
                    unplaced.append(entry)
                    continue
                }
                for number in located.episodes { placed[[located.season, number], default: []].append(entry) }
            }
        }

        var episodes: [[Int]: LibraryEpisode] = [:]
        for info in detail?.episodes ?? [] where (info.released ?? .distantPast) <= now || placed[[info.season, info.number]] != nil {
            episodes[[info.season, info.number]] = LibraryEpisode(season: info.season, number: info.number, info: info, files: [])
        }
        for (key, list) in placed {
            var episode = episodes[key] ?? LibraryEpisode(season: key[0], number: key[1], info: nil, files: [])
            episode.files = list.sorted(by: Self.preferred)
            episodes[key] = episode
        }
        let bySeason = Dictionary(grouping: episodes.values, by: \.season)
        seasons = bySeason.keys
            // Specials last, and only when the library holds one: metadata lists dozens nobody has.
            .filter { $0 > 0 || bySeason[$0]!.contains(where: \.isAvailable) }
            .sorted { ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1) }
            .map { LibrarySeason(number: $0, episodes: bySeason[$0]!.sorted { $0.number < $1.number }) }
        self.unplaced = unplaced
    }

    public var hasEpisodes: Bool { seasons.contains { !$0.available.isEmpty } }

    /// Episodes the library holds, in order, from every season.
    public var available: [LibraryEpisode] { seasons.flatMap(\.available) }

    /// The held episodes from `episode` to the end of the series ("Play from here").
    public func available(from episode: LibraryEpisode) -> [LibraryEpisode] {
        available.filter { ($0.season, $0.number) >= (episode.season, episode.number) }
    }

    static func preferred(_ a: EpisodeFile, _ b: EpisodeFile) -> Bool {
        if a.isReady != b.isReady { return a.isReady }
        let ra = resolutionRank(a.resolution), rb = resolutionRank(b.resolution)
        if ra != rb { return ra > rb }
        if (a.size ?? 0) != (b.size ?? 0) { return (a.size ?? 0) > (b.size ?? 0) }
        return a.id < b.id
    }

    private static func resolutionRank(_ resolution: String?) -> Int {
        switch resolution {
        case "2160p": 4
        case "1440p": 3
        case "1080p": 2
        case "720p": 1
        default: 0
        }
    }

    // MARK: - Placing files

    /// Season and episode(s) a file holds. The file name's own code wins (`S01E02`, `1x02`); otherwise the
    /// season comes from a folder ("Season 1", "S01") or the release ("Show.S01.1080p"), and the episode from
    /// the name: "E05", "Episode 5", "105" (season 1), or a leading "05 - Title".
    public static func locate(_ path: String, in release: MediaGuess) -> (season: Int, episodes: [Int])? {
        let components = path.split(separator: "/").map(String.init)
        guard let fileName = components.last else { return nil }
        if case .episodes(let season, let numbers) = ReleaseParser.guess(fileName).scope { return (season, numbers) }

        var season: Int?
        for folder in components.dropLast().reversed() {
            switch ReleaseParser.guess(folder).scope {
            case .season(let number), .episodes(let number, _): season = number
            default: continue
            }
            break
        }
        if season == nil, case .season(let number) = release.scope { season = number }
        guard let season, let episode = episodeNumber(in: fileName, season: season) else { return nil }
        return (season, [episode])
    }

    private static func episodeNumber(in fileName: String, season: Int) -> Int? {
        var text = ((fileName as NSString).deletingPathExtension).lowercased()
            .replacingOccurrences(of: #"[._\[\]\(\)]"#, with: " ", options: .regularExpression)
        // Technical numbers that look like episodes: codecs, resolutions, audio channels, years.
        text = text.replacingOccurrences(
            of: #"\b(h ?26[45]|x26[45]|\d{3,4}[pi]|[257] [01]|(19|20)\d{2}|10 ?bit)\b"#,
            with: " ", options: .regularExpression
        )
        if let number = firstNumber(text, #"\b(?:e|ep|episode|episodio|odcinek) ?(\d{1,3})\b"#) { return number }
        if season < 10, let match = text.range(of: #"\b\d{3}\b"#, options: .regularExpression) {
            let digits = Array(text[match])
            if Int(String(digits[0])) == season, let number = Int(String(digits[1...])), number > 0 { return number }
        }
        if let number = firstNumber(text, #"^\s*(\d{1,3})\b"#), number > 0 { return number }
        return nil
    }

    private static func firstNumber(_ text: String, _ pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

/// What Infuse gets for "Play season" or "Play all": one file per episode, in order, named so Infuse
/// recognises the show and episode (its `filename` parameter) whatever the link's path says.
public struct EpisodePlaylist: Sendable {
    public struct Entry: Sendable, Hashable {
        public let episode: LibraryEpisode
        public let file: EpisodeFile
        /// "Lost - S01E01.mkv".
        public let filename: String
    }

    public let entries: [Entry]

    /// - Parameter choice: a file the user picked for an episode instead of the preferred one.
    public init(_ episodes: [LibraryEpisode], title: String, choice: [LibraryEpisode.ID: EpisodeFile] = [:]) {
        var entries: [Entry] = []
        var seen = Set<String>()
        for episode in episodes {
            guard let file = choice[episode.id] ?? episode.files.first else { continue }
            // A double episode ("S01E01-E02") is one file listed under both episodes.
            guard seen.insert(file.id).inserted else { continue }
            entries.append(Entry(episode: episode, file: file, filename: Self.filename(title: title, episode: episode, file: file)))
        }
        self.entries = entries
    }

    static func filename(title: String, episode: LibraryEpisode, file: EpisodeFile) -> String {
        let clean = title.replacingOccurrences(of: #"[/:\\?*"<>|]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        let ext = (file.name as NSString).pathExtension
        return "\(clean) - \(episode.code)" + (ext.isEmpty ? "" : ".\(ext)")
    }
}
