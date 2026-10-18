import Foundation

/// What the search field looks for. Movies & TV searches titles (TMDB or the metadata addon), then each
/// title's sources come from the stream addons and Dove's indexers; every other category searches release
/// names through Dove's own Newznab/Torznab indexers only (addons cannot search books or music by text).
public enum SearchCategory: String, CaseIterable, Sendable, Hashable, Codable {
    case media
    case books
    case audiobooks
    case music
    case software
    /// Hidden unless the user shows adult content.
    case adult
    /// Free text in every category.
    case all

    /// The indexers' category for a name search; nil for Movies & TV, which searches titles.
    public var newznabCategory: NewznabCategory? {
        switch self {
        case .media: nil
        case .books: .books
        case .audiobooks: .audiobooks
        case .music: .music
        case .software: .software
        case .adult: .adult
        case .all: .all
        }
    }

    /// Books and Audiobooks search the book metadata services first.
    public var bookFormat: BookFormat? {
        switch self {
        case .books: .ebook
        case .audiobooks: .audiobook
        default: nil
        }
    }

    /// Only Movies & TV asks the Stremio addons.
    public var usesAddons: Bool { self == .media }

    public var displayName: String {
        switch self {
        case .media: "Movies & TV"
        case .books: "Books"
        case .audiobooks: "Audiobooks"
        case .music: "Music"
        case .software: "Software"
        case .adult: "Adult"
        case .all: "All"
        }
    }

    public var symbolName: String {
        switch self {
        case .media: "film"
        case .books: "book"
        case .audiobooks: "headphones"
        case .music: "music.note"
        case .software: "shippingbox"
        case .adult: "eye.slash"
        case .all: "square.grid.2x2"
        }
    }

    /// Old saves said `other` for every name search: that is All now. Anything unknown is Movies & TV.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "other" ? .all : SearchCategory(rawValue: raw) ?? .media
    }
}
