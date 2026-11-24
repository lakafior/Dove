import Foundation

/// Where an ebook was left in Dove's reader: an EPUB CFI (`epubcfi(/6/14!/4/2/1:0)`, epub.js's) or a PDF page
/// (`page:12`), with how far through the book that is.
public struct ReadingPosition: Sendable, Hashable, Codable {
    public var location: String
    /// 0…1; nil until the reader has counted the book's pages.
    public var progress: Double?
    public var updatedAt: Date

    public init(location: String, progress: Double?, updatedAt: Date = .now) {
        self.location = location
        self.progress = progress.map { min(max($0, 0), 1) }
        self.updatedAt = updatedAt
    }

    /// `page:12` → 12 (PDF pages count from 1).
    public var page: Int? {
        guard location.hasPrefix("page:") else { return nil }
        return Int(location.dropFirst("page:".count)).flatMap { $0 > 0 ? $0 : nil }
    }

    public static func page(_ number: Int, of count: Int) -> ReadingPosition {
        ReadingPosition(location: "page:\(number)", progress: count > 0 ? Double(number) / Double(count) : nil)
    }
}

/// Positions of every ebook read in Dove, keyed by `BookGuess.key` (like `AudiobookPositions`, so another release
/// of the same book opens at the same chapter when its CFI still fits). One Keychain item
/// (`CredentialKey.readingPositions`), so iCloud Keychain carries it to the user's other devices.
public struct ReadingPositions: Sendable, Codable, Equatable {
    public private(set) var entries: [String: ReadingPosition] = [:]
    static let limit = 300

    public init() {}

    public subscript(key: String) -> ReadingPosition? { entries[key] }

    public mutating func set(_ position: ReadingPosition, for key: String) {
        entries[key] = position
        if entries.count > Self.limit {
            let oldest = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }.prefix(entries.count - Self.limit)
            for (key, _) in oldest { entries[key] = nil }
        }
    }

    /// Keeps the newer position of each book: another device may have saved since this one loaded.
    public mutating func merge(_ other: ReadingPositions) {
        for (key, position) in other.entries where (entries[key]?.updatedAt ?? .distantPast) < position.updatedAt {
            entries[key] = position
        }
    }
}

extension SharedConfiguration {
    public static func readingPositions(from keychain: KeychainStore) -> ReadingPositions {
        guard let json = try? keychain.get(.readingPositions),
              let positions = try? JSONDecoder().decode(ReadingPositions.self, from: Data(json.utf8))
        else { return ReadingPositions() }
        return positions
    }

    /// Saves one book's place, merged with what is stored so a newer place from another device is kept.
    public static func saveReadingPosition(_ position: ReadingPosition, for key: String, to keychain: KeychainStore) {
        var merged = readingPositions(from: keychain)
        var mine = ReadingPositions()
        mine.set(position, for: key)
        merged.merge(mine)
        guard let data = try? JSONEncoder().encode(merged) else { return }
        try? keychain.set(String(decoding: data, as: UTF8.self), for: .readingPositions)
    }
}
