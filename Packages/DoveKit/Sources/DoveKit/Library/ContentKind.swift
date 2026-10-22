import Foundation

/// What a library item holds. `video` gets titles, posters and Infuse; `books` and `audiobooks` get covers
/// (`BookMetadata`); the rest are listed by name. A separate kind per family leaves room for their own metadata
/// (music, games).
/// `games` covers PC and console games and ROMs alike; the platform (`GamePlatform`) is an attribute.
/// `adult` is hidden everywhere (Library, Files, Search › Other) unless the user shows it.
public enum ContentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case video, music, books, audiobooks, games, software, adult, other

    /// The kind of a Newznab category: 2000 movies and 5000 TV are video, 3000 audio (3030 audiobooks), 1000
    /// consoles and 4050 PC games are games, the rest of 4000 PC software, 6000 XXX, 7000 books.
    public init(newznabCategory category: Int) {
        if category == 3030 { self = .audiobooks; return }
        if category == 4050 { self = .games; return }
        switch category / 1000 {
        case 1: self = .games
        case 2, 5: self = .video
        case 3: self = .music
        case 4: self = .software
        case 6: self = .adult
        case 7: self = .books
        default: self = .other
        }
    }

    public var displayName: String {
        switch self {
        case .video: "Video"
        case .music: "Music"
        case .books: "Books"
        case .audiobooks: "Audiobooks"
        case .games: "Games"
        case .software: "Software"
        case .adult: "Adult"
        case .other: "Other"
        }
    }

    /// SF Symbol for rows.
    public var symbol: String {
        switch self {
        case .video: "film"
        case .music: "music.note"
        case .books: "book"
        case .audiobooks: "headphones"
        case .games: "gamecontroller"
        case .software: "shippingbox"
        case .adult: "eye.slash"
        case .other: "doc"
        }
    }
}

/// Decides an item's kind, most reliable evidence first:
/// 0. an adult marker (`XXX`) in the name: such releases are video files, and must not get posters or titles;
/// 1. its files (or the item's own name, for a single file), weighed by size;
/// 2. markers in the release name (`1080p`, `S01E02` → video; `Audiobook`, `Unabridged` → audiobooks; `FLAC` → music;
///    `FitGirl`, `PS2`, `No-Intro` → games; `x64` → software…; an ISO under a game's name is a game); audio files under an audiobook name are an audiobook, not music;
/// 3. a year or a season in the name → video (how most releases are named); otherwise `other`.
///
/// Real-Debrid and Offcloud list items without files, so for them only the name counts until the item
/// is opened; the app then remembers what the files said.
public enum ContentClassifier {
    static let extensions: [ContentKind: Set<String>] = [
        .video: FileKind.videoExtensions,
        .music: ["flac", "mp3", "m4a", "aac", "ogg", "opus", "wav", "alac", "ape", "wv", "dsf", "dff", "aiff"],
        .books: ["epub", "pdf", "mobi", "azw", "azw3", "cbz", "cbr", "djvu", "fb2"],
        .audiobooks: ["m4b"],
        .games: GamePlatform.fileExtensions,
        .software: ["iso", "img", "dmg", "pkg", "exe", "msi", "apk", "ipa", "appimage", "deb", "rpm"],
    ]

    /// The kind a file name's extension stands for; nil for extras such as `.nfo`, `.jpg` or archives.
    public static func kind(ofFile name: String) -> ContentKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return extensions.first { $0.value.contains(ext) }?.key
    }

    public static func classify(name: String, files: [LibraryFile]) -> ContentKind {
        if isAdult(name: name) { return .adult }
        if let kind = byFiles(files) ?? kind(ofFile: name) {
            if kind == .music && isAudiobook(name: name) { return .audiobooks }
            if kind == .software && isGame(name: name) { return .games }
            return kind
        }
        return byName(name)
    }

    /// The kind with the most bytes (or files, when the service gives no sizes). Video samples do not count;
    /// a trailer next to a game ISO loses to the ISO.
    static func byFiles(_ files: [LibraryFile]) -> ContentKind? {
        var weight: [ContentKind: Int64] = [:]
        for file in files {
            guard let kind = kind(ofFile: file.name), !(kind == .video && FileKind.isSample(file.name)) else { continue }
            weight[kind, default: 0] += max(file.size ?? 1, 1)
        }
        return weight.max { ($0.value, $0.key == .video ? 1 : 0) < ($1.value, $1.key == .video ? 1 : 0) }?.key
    }

    private static let musicMarkers =
        #"\b(flac|mp3|320 ?kbps|v0|24 ?bit|16 ?bit|lossless|discography|vinyl|alac|web flac|cd ?rip|soundtrack|ost)\b"#
    private static let audiobookMarkers =
        #"\b(audio ?books?|unabridged|abridged|narrated by|read by|m4b)\b"#
    private static let bookMarkers =
        #"\b(epub|pdf|mobi|azw3|e-?books?|comics?|cbz|cbr|magazine|retail ebook)\b"#
    /// Scene groups and repackers that release games, and ROM collections' words.
    private static let gameMarkers =
        #"\b(fitgirl|dodi|elamigos|gog|codex|skidrow|plaza|empress|tenoke|rune|flt|razor1911|cpy|hoodlum|darksiders|kaos|chronos|p2p games?|no-?intro|redump|rom ?set|roms?)\b"#
    private static let softwareMarkers =
        #"\b(x64|x86|amd64|arm64|win(dows)?|win64|win32|macos|mac os|linux|setup|installer|portable|multilingual|repack|v\d+(\.\d+){1,3})\b"#

    private static let adultMarkers = #"\bxxx\b"#

    /// Release names that say they are adult content. Many are not marked: the user can change an item's kind.
    public static func isAdult(name: String) -> Bool {
        let text = name.lowercased().replacingOccurrences(of: #"[._\-\[\]\(\)]"#, with: " ", options: .regularExpression)
        return text.range(of: adultMarkers, options: .regularExpression) != nil
    }

    /// A game by its name: a repacker, scene group or ROM word, or a console named in it.
    static func isGame(name: String) -> Bool {
        markerText(name).range(of: gameMarkers, options: .regularExpression) != nil
            || GamePlatform(releaseName: name).map { $0 != .pc } == true
    }

    static func isAudiobook(name: String) -> Bool {
        markerText(name).range(of: audiobookMarkers, options: .regularExpression) != nil
    }

    private static func markerText(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"[._\[\]\(\)]"#, with: " ", options: .regularExpression)
    }

    static func byName(_ name: String) -> ContentKind {
        let traits = ReleaseParser.parse(name)
        if traits.resolution != nil || traits.encode != nil || traits.quality != nil
            || !traits.seasons.isEmpty || !traits.episodes.isEmpty {
            return .video
        }
        let text = markerText(name)
        if text.range(of: audiobookMarkers, options: .regularExpression) != nil { return .audiobooks }
        if text.range(of: musicMarkers, options: .regularExpression) != nil { return .music }
        if text.range(of: bookMarkers, options: .regularExpression) != nil { return .books }
        if isGame(name: name) { return .games }
        if text.range(of: softwareMarkers, options: .regularExpression) != nil { return .software }
        let guess = ReleaseParser.guess(name)
        return guess.year != nil || guess.scope != nil ? .video : .other
    }
}
