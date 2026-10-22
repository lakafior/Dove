import Foundation

/// How Dove files things in iCloud Drive › Dove, Calibre-style for books:
///
///     Books/Andy Weir/Project Hail Mary/Project Hail Mary - Andy Weir.epub
///     Audiobooks/Andy Weir/Project Hail Mary/01.mp3 …
///     Games/SNES/The Legend of Zelda - A Link to the Past/Legend of Zelda, The - A Link to the Past (USA).sfc
///     Music/<item>/…   Video/<item>/…   Software/…   Adult/…   Other/…
///
/// One folder per work keeps several formats (EPUB and PDF, a cover later) together and lets Calibre import the
/// tree. Folder names carry author and title, so the Library reads them back without a search. Games go by platform,
/// then game (the files keep their names: a ROM's says its region and revision), so an emulator's folder can point
/// at one platform's.
public enum LibraryFolderLayout {
    public static func folderName(_ kind: ContentKind) -> String {
        switch kind {
        case .books: "Books"
        case .audiobooks: "Audiobooks"
        case .music: "Music"
        case .video: "Video"
        case .games: "Games"
        case .software: "Software"
        case .adult: "Adult"
        case .other: "Other"
        }
    }

    /// The kind a top-level folder holds.
    public static func kind(ofFolder name: String) -> ContentKind? {
        ContentKind.allCases.first { folderName($0) == name }
    }

    /// Kinds filed by author, then title.
    public static func byAuthor(_ kind: ContentKind) -> Bool { kind == .books || kind == .audiobooks }

    /// Kinds filed in two levels (author or platform, then the work): each work folder is one Library item.
    public static func isTwoLevel(_ kind: ContentKind) -> Bool { byAuthor(kind) || kind == .games }

    /// Games whose platform is not known.
    public static let otherPlatforms = "Other Platforms"

    /// The folder a platform's games go in.
    public static func folderName(_ platform: GamePlatform?) -> String {
        platform?.displayName ?? otherPlatforms
    }

    /// The Library name of a game folder: "Title [SNES]" (`GamePlatform(releaseName:)` reads the platform back).
    public static func itemName(platformFolder: String, title: String) -> String {
        platformFolder == otherPlatforms ? title : "\(title) [\(platformFolder)]"
    }

    /// A game's platform: the release names it (extension, marker), else a PC scene group or repacker says PC,
    /// else the game is on one platform only.
    static func platform(game: GameSummary?, names: [String]) -> GamePlatform? {
        if let named = names.lazy.compactMap(GamePlatform.init(releaseName:)).first { return named }
        if names.contains(where: GamePlatform.isPCRelease) { return .pc }
        return game.flatMap { $0.platforms.count == 1 ? $0.platforms.first : nil }
    }

    public static let unknownAuthor = "Unknown Author"

    /// Where a download goes, relative to iCloud Drive › Dove.
    public struct Placement: Sendable, Hashable {
        /// Folder path, `/`-separated.
        public var folder: String
        /// The file's name in it (may hold a subfolder for files inside a many-file item: `CD1/01.mp3`).
        public var fileName: String
    }

    /// - Parameters:
    ///   - kind: what the file is.
    ///   - book: the book it was found for (metadata wins over names).
    ///   - game: the game it was found for (its title names the folder; the platform comes from the names first).
    ///   - itemName: the release or item it belongs to (author and title are read from it when there is no book).
    ///   - fileName: the file's own name, a path inside the item for many-file items.
    ///   - singleFile: the item is this one file (a book file is then renamed "Title - Author.ext").
    public static func placement(
        kind: ContentKind,
        book: BookSummary? = nil,
        game: GameSummary? = nil,
        itemName: String,
        fileName: String,
        singleFile: Bool
    ) -> Placement {
        let top = folderName(kind)
        if kind == .games {
            let platform = folderName(platform(game: game, names: [itemName, fileName]))
            let collection = GameGuess.isCollection(name: itemName)
            let title = collection ? stripExtension(itemName) : (game?.title ?? GameGuess(releaseName: itemName).title)
            return Placement(folder: [top, component(platform), component(title)].joined(separator: "/"), fileName: cleanPath(fileName))
        }
        guard byAuthor(kind) else {
            let file = cleanPath(fileName)
            return singleFile
                ? Placement(folder: top, fileName: file)
                : Placement(folder: top + "/" + component(stripExtension(itemName)), fileName: file)
        }
        let (author, title) = authorAndTitle(kind: kind, book: book, name: singleFile ? fileName : itemName)
        let folder = [top, component(author), component(title)].joined(separator: "/")
        if singleFile {
            let ext = (fileName as NSString).pathExtension
            let base = component("\(title) - \(author)")
            return Placement(folder: folder, fileName: ext.isEmpty ? base : "\(base).\(ext.lowercased())")
        }
        return Placement(folder: folder, fileName: cleanPath(fileName))
    }

    /// Author and title from the book, else from the name: "Title -- Author -- …" (shadow-library file names),
    /// else `BookGuess` ("Author - Title").
    static func authorAndTitle(kind: ContentKind, book: BookSummary?, name: String) -> (author: String, title: String) {
        if let book {
            return (book.authors.first ?? unknownAuthor, book.searchTitle)
        }
        let base = stripExtension(name)
        let parts = base.components(separatedBy: " -- ").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty {
            // Lists of authors come as "A; B" or "A, B": the first one names the folder.
            let author = parts[1].components(separatedBy: CharacterSet(charactersIn: ";")).first ?? parts[1]
            return (author.trimmingCharacters(in: .whitespaces), parts[0])
        }
        let guess = BookGuess(releaseName: base, format: kind == .audiobooks ? .audiobook : .ebook)
        return (guess.author ?? unknownAuthor, guess.title.isEmpty ? base : guess.title)
    }

    /// The Library name of a work folder: "Author - Title" (what `BookGuess` reads back).
    public static func itemName(author: String, title: String) -> String {
        author == unknownAuthor ? title : "\(author) - \(title)"
    }

    /// A safe single path component: no separators, no leading dots, at most 120 characters.
    public static func component(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .replacingOccurrences(of: #"[\\?*"<>|\u{0}-\u{1F}]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    /// A relative path with every component made safe.
    static func cleanPath(_ path: String) -> String {
        path.split(separator: "/").map { component(String($0)) }.joined(separator: "/")
    }

    static func stripExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        // "epub", "m4b", "azw3"; not "1080p" or "2023".
        guard (2...4).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }), ext.contains(where: \.isLetter)
        else { return name }
        return (name as NSString).deletingPathExtension
    }
}
