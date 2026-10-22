import Foundation

/// Title, platform, region and version read from a game's release or ROM name:
/// "Legend of Zelda, The - A Link to the Past (USA) (Rev 1).sfc" (No-Intro/Redump),
/// "Elden.Ring.Shadow.of.the.Erdtree-RUNE", "Baldurs.Gate.3.v4.1.1.3767641-GOG" (scene),
/// "Red Dead Redemption 2 [v 1436.28 + DLCs] [FitGirl Repack]" (repacks),
/// "The_Legend_of_Zelda_Tears_of_the_Kingdom_NSW-VENOM" (consoles).
public struct GameGuess: Sendable, Hashable, Codable {
    public var title: String
    public var platform: GamePlatform?
    /// No-Intro/Redump's first region: "USA", "Europe", "Japan", "World".
    public var region: String?
    /// "1.6.8", "4.1.1.3767641", "Rev 1".
    public var version: String?
    /// "Deluxe Edition", "Game of the Year Edition", "Complete Edition".
    public var edition: String?
    /// Only a year in brackets: titles hold numbers ("Cyberpunk 2077").
    public var year: Int?

    /// Groups releases of one game, whatever the platform: `game|eldenring`.
    public var key: String { "game|\(MediaGuess.normalize(title))" }

    /// What a metadata search gets.
    public var query: String { title }

    public init(title: String, platform: GamePlatform? = nil, region: String? = nil, version: String? = nil,
                edition: String? = nil, year: Int? = nil) {
        self.title = title
        self.platform = platform
        self.region = region
        self.version = version
        self.edition = edition
        self.year = year
    }

    private static let archiveExtensions: Set<String> = ["zip", "7z", "rar", "iso", "chd", "rvz", "cue", "bin", "pkg"]

    static let regions = [
        "USA", "Europe", "Japan", "World", "Asia", "Korea", "China", "Germany", "France", "Spain", "Italy",
        "Australia", "Brazil", "Canada", "UK", "Netherlands", "Sweden", "Russia", "Poland",
    ]

    /// Editions named after the title; removed from it and kept in `edition`.
    private static let editionPattern =
        #"(?i)\b(game of the year|goty|deluxe|complete|definitive|ultimate|gold|premium|digital deluxe|enhanced|remastered|director'?s cut|collector'?s|special|legendary|anniversary|standard)( edition)?\b"#

    /// Words after which a scene name holds no more title.
    private static let stopPattern =
        #"(?i)\s(v ?\d[\d\.]*|build \d+|update|multi ?\d+|repack|incl|proper|readnfo|crack(ed|fix)?|dlcs?|nsw|nsp|xci|ps[2-5]|psp|x360|xbox ?\d*|wii ?u?|3ds|nds|gba|switch|pc|win(64|32)?|x64|linux|macos|mac|eshop|update)\b.*$"#

    public init(releaseName name: String) {
        var base = (name as NSString).lastPathComponent.trimmingCharacters(in: .whitespaces)
        let ext = (base as NSString).pathExtension.lowercased()
        if GamePlatform.fileExtensions.contains(ext) || Self.archiveExtensions.contains(ext) {
            base = (base as NSString).deletingPathExtension
        }
        platform = GamePlatform(releaseName: name)
        region = Self.firstRegion(in: base)
        year = Self.bracketedYear(in: base)
        version = Self.version(in: base)

        // Scene names: dots or underscores for spaces, "-GROUP" at the end.
        if !base.contains(" ") {
            base = base.replacingOccurrences(of: #"-[A-Za-z0-9]+$"#, with: "", options: .regularExpression)
            base = base.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        } else {
            base = base.replacingOccurrences(of: #"\s+-\s*[A-Za-z0-9]+$"#, with: "", options: .regularExpression,
                                             onlyWhen: Self.isGroup)
        }
        // Brackets and parentheses: regions, versions, repackers, title IDs.
        base = base.replacingOccurrences(of: #"\[[^\]]*\]|\([^\)]*\)|\{[^\}]*\}"#, with: " ", options: .regularExpression)
        base = " " + base.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        base = base.replacingOccurrences(of: Self.stopPattern, with: "", options: .regularExpression)
        if let found = base.range(of: Self.editionPattern, options: .regularExpression) {
            edition = Self.editionName(String(base[found]))
            base = String(base[..<found.lowerBound])
        }
        title = Self.tidy(base)
        if title.isEmpty { title = Self.tidy((name as NSString).deletingPathExtension) }
    }

    /// No-Intro moves articles to the end: "Legend of Zelda, The - A Link to the Past" → "The Legend of Zelda - A
    /// Link to the Past". Trailing dashes and spare spaces go.
    private static func tidy(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–:+"))
        if let match = text.range(of: #"^(.+?), (The|A|An)\b"#, options: .regularExpression) {
            let head = text[match]
            let comma = head.range(of: ", ", options: .backwards)!
            text = String(head[comma.upperBound...]) + " " + String(head[..<comma.lowerBound]) + text[match.upperBound...]
        }
        return text
    }

    private static func isGroup(_ suffix: String) -> Bool {
        let group = suffix.trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        return group.count >= 3 && group == group.uppercased() && group.rangeOfCharacter(from: .letters) != nil
    }

    private static func editionName(_ text: String) -> String {
        let words = text.trimmingCharacters(in: .whitespaces)
        let named = words.lowercased() == "goty" ? "Game of the Year" : words.capitalized
        return named.lowercased().hasSuffix("edition") ? named : named + " Edition"
    }

    private static func firstRegion(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\(([^\)]+)\)"#) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let parts = text[range].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if let region = parts.first(where: regions.contains) { return region }
        }
        return nil
    }

    private static func bracketedYear(in text: String) -> Int? {
        guard let match = text.range(of: #"[\(\[](19[7-9]\d|20[0-4]\d)[\)\]]"#, options: .regularExpression) else { return nil }
        return Int(text[match].filter(\.isNumber))
    }

    /// "v1.6.8", "v 1436.28", "Build 12345", No-Intro's "(Rev 1)".
    private static func version(in text: String) -> String? {
        if let rev = text.range(of: #"\(Rev \w+\)"#, options: .regularExpression) {
            return String(text[rev].dropFirst().dropLast())
        }
        let spaced = text.replacingOccurrences(of: "_", with: " ")
        guard let found = spaced.range(of: #"(?i)(?<![A-Za-z])v ?\d+(\.\d+)+|(?i)\bbuild[ .]?\d+"#, options: .regularExpression) else {
            return nil
        }
        let version = spaced[found]
        return version.lowercased().hasPrefix("build")
            ? "Build " + version.filter(\.isNumber)
            : String(version.drop { !$0.isNumber })
    }

    /// Whole collections ("No-Intro SNES romset", "Redump PS1 set", 50+ game files): one item, never matched file
    /// by file.
    public static func isCollection(name: String, gameFiles: Int = 0) -> Bool {
        if gameFiles > 50 { return true }
        let text = name.lowercased().replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        return text.range(of: #"\b(rom ?set|romset|full set|complete set|no-?intro|redump|roms collection|rom collection|\d+ in 1)\b"#,
                          options: .regularExpression) != nil
    }
}

private extension String {
    /// Replaces the first match of `pattern` only when `check` accepts its text.
    func replacingOccurrences(of pattern: String, with replacement: String, options: CompareOptions, onlyWhen check: (String) -> Bool) -> String {
        guard let found = range(of: pattern, options: options), check(String(self[found])) else { return self }
        return replacingCharacters(in: found, with: replacement)
    }
}

extension ShelfItem {
    /// Title and platform from the name, for game items; nil for collections and other kinds.
    public var gameGuess: GameGuess? {
        guard kind == .games, !GameGuess.isCollection(name: name, gameFiles: item.files.filter { ContentClassifier.kind(ofFile: $0.name) == .games }.count) else {
            return nil
        }
        return GameGuess(releaseName: name)
    }
}
