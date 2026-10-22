import Foundation

/// The category an NZB is filed under on Usenet services that sort jobs into folders (nzbdav/InfiniDysk:
/// `/content/{category}/…`). Lowercase, matching InfiniDysk's default category names; the user's server lists
/// them under Settings › SABnzbd › Categories. Nil means the server's manual-upload category (`uncategorized`).
public enum AddCategory: String, Sendable, CaseIterable, Hashable {
    case movies, tv, audio, audiobooks, books, games, software, xxx

    public init(mediaType: MediaType) {
        self = mediaType == .movie ? .movies : .tv
    }

    /// From a Newznab/Torznab category (2000 movies, 5000 TV, 3000 audio, 4000 PC, 6000 XXX, 7000 books).
    /// Audiobooks (3030) get their own folder, apart from music; games (1000 consoles, 4050 PC games) theirs.
    public init?(newznabCategory category: Int) {
        if category == 3030 { self = .audiobooks; return }
        if category == 4050 { self = .games; return }
        switch category / 1000 {
        case 1: self = .games
        case 2: self = .movies
        case 5: self = .tv
        case 3: self = .audio
        case 4: self = .software
        case 6: self = .xxx
        case 7: self = .books
        default: return nil
        }
    }

    /// Guessed from a release or NZB file name, like the library classifies items; nil when nothing fits.
    public init?(releaseName name: String) {
        let base = name.lowercased().hasSuffix(".nzb") ? String(name.dropLast(4)) : name
        switch ContentClassifier.classify(name: base, files: []) {
        case .video: self.init(mediaType: ReleaseParser.guess(base).type)
        case .music: self = .audio
        case .books: self = .books
        case .audiobooks: self = .audiobooks
        case .games: self = .games
        case .software: self = .software
        case .adult: self = .xxx
        case .other: return nil
        }
    }
}
