import Foundation

/// What a library item holds. Only `video` gets titles, posters and Infuse; the rest are listed by name.
/// A separate kind per family leaves room for their own metadata later (music, games).
public enum ContentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case video, music, books, software, other

    /// The kind of a Newznab category: 2000 movies and 5000 TV are video, 3000 audio, 4000 PC, 7000 books.
    public init(newznabCategory category: Int) {
        switch category / 1000 {
        case 2, 5: self = .video
        case 3: self = .music
        case 4: self = .software
        case 7: self = .books
        default: self = .other
        }
    }

    public var displayName: String {
        switch self {
        case .video: "Video"
        case .music: "Music"
        case .books: "Books"
        case .software: "Software"
        case .other: "Other"
        }
    }

    /// SF Symbol for rows.
    public var symbol: String {
        switch self {
        case .video: "film"
        case .music: "music.note"
        case .books: "book"
        case .software: "shippingbox"
        case .other: "doc"
        }
    }
}

/// Decides an item's kind, most reliable evidence first:
/// 1. its files (or the item's own name, for a single file), weighed by size;
/// 2. markers in the release name (`1080p`, `S01E02` → video; `FLAC` → music; `x64`, `GOG` → software…);
/// 3. a year or a season in the name → video (how most releases are named); otherwise `other`.
///
/// Real-Debrid and Offcloud list items without files, so for them only the name counts until the item
/// is opened; the app then remembers what the files said.
public enum ContentClassifier {
    static let extensions: [ContentKind: Set<String>] = [
        .video: FileKind.videoExtensions,
        .music: ["flac", "mp3", "m4a", "aac", "ogg", "opus", "wav", "alac", "ape", "wv", "dsf", "dff", "aiff"],
        .books: ["epub", "pdf", "mobi", "azw", "azw3", "cbz", "cbr", "djvu", "fb2", "m4b"],
        .software: ["iso", "img", "dmg", "pkg", "exe", "msi", "apk", "ipa", "appimage", "deb", "rpm", "nsp", "xci"],
    ]

    /// The kind a file name's extension stands for; nil for extras such as `.nfo`, `.jpg` or archives.
    public static func kind(ofFile name: String) -> ContentKind? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return extensions.first { $0.value.contains(ext) }?.key
    }

    public static func classify(name: String, files: [LibraryFile]) -> ContentKind {
        if let kind = byFiles(files) ?? kind(ofFile: name) { return kind }
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
    private static let bookMarkers =
        #"\b(epub|pdf|mobi|azw3|e-?books?|audiobooks?|comics?|cbz|cbr|magazine|retail ebook)\b"#
    private static let softwareMarkers =
        #"\b(x64|x86|amd64|arm64|win(dows)?|win64|win32|macos|mac os|linux|setup|installer|portable|multilingual|fitgirl|dodi|elamigos|gog|codex|skidrow|plaza|empress|tenoke|rune|flt|razor1911|repack|v\d+(\.\d+){1,3})\b"#

    static func byName(_ name: String) -> ContentKind {
        let traits = ReleaseParser.parse(name)
        if traits.resolution != nil || traits.encode != nil || traits.quality != nil
            || !traits.seasons.isEmpty || !traits.episodes.isEmpty {
            return .video
        }
        let text = name.lowercased()
            .replacingOccurrences(of: #"[._\[\]\(\)]"#, with: " ", options: .regularExpression)
        if text.range(of: musicMarkers, options: .regularExpression) != nil { return .music }
        if text.range(of: bookMarkers, options: .regularExpression) != nil { return .books }
        if text.range(of: softwareMarkers, options: .regularExpression) != nil { return .software }
        let guess = ReleaseParser.guess(name)
        return guess.year != nil || guess.scope != nil ? .video : .other
    }
}
