import Foundation

/// What Dove knew when it added an item: the release name the search showed and the title it was found for.
/// Services sometimes list an item under a random string (obfuscated torrents and NZBs, a magnet without
/// metadata yet); the hint lets the library still show and match it.
public struct AddedHint: Codable, Sendable, Hashable {
    /// The release name from the search row (torrent folder, else the file or indexer title).
    public var releaseName: String?
    /// The movie or series the user was looking at when adding, if any.
    public var media: MediaSummary?
    public var addedAt: Date

    public init(releaseName: String?, media: MediaSummary? = nil, addedAt: Date = .now) {
        self.releaseName = releaseName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        self.media = media
        self.addedAt = addedAt
    }

    public var isEmpty: Bool { releaseName == nil && media == nil }
}

/// Hints for items Dove added, keyed by `ShelfItem.id` and by info hash: Reinsert and Move give an item a new ID,
/// the hash stays. Device-local, like library matches. Entries older than `maxAge` are dropped on save.
public struct AddedHints: Codable, Sendable, Equatable {
    public var byItem: [String: AddedHint] = [:]
    public var byHash: [String: AddedHint] = [:]

    public static var maxAge: TimeInterval { 365 * 24 * 3600 }

    public init() {}

    public func hint(for item: LibraryItem) -> AddedHint? {
        byItem[ShelfItem.id(backend: item.backend, itemID: item.id)]
            ?? item.infoHash.flatMap { byHash[$0.lowercased()] }
    }

    public mutating func record(_ hint: AddedHint, backend: BackendID, itemIDs: [LibraryItem.ID], infoHash: String?) {
        guard !hint.isEmpty else { return }
        for itemID in itemIDs { byItem[ShelfItem.id(backend: backend, itemID: itemID)] = hint }
        if let hash = infoHash.flatMap(InfoHash.normalized) { byHash[hash] = hint }
    }

    public mutating func prune(now: Date = .now) {
        byItem = byItem.filter { now.timeIntervalSince($0.value.addedAt) < Self.maxAge }
        byHash = byHash.filter { now.timeIntervalSince($0.value.addedAt) < Self.maxAge }
    }

    public static func load(from url: URL) -> AddedHints? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AddedHints.self, from: data)
    }

    public func save(to url: URL) throws {
        var pruned = self
        pruned.prune()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pruned).write(to: url, options: .atomic)
    }
}

/// Picks a readable name for a library item whose service lists it under a random string.
public enum LibraryNaming {
    /// The name to guess the title from: the service's own when it reads like a release, else the hint's
    /// release name, else the item's files (one video, or the folder they share), else the service's after all.
    /// A readable service name always wins: a search row may name one episode of the pack it added.
    public static func readableName(of item: LibraryItem, hint: AddedHint?) -> String {
        guard looksObfuscated(item.name) else { return item.name }
        if let release = hint?.releaseName, !looksObfuscated(release) { return release }
        if let fromFiles = nameFromFiles(item.files) { return fromFiles }
        if let media = hint?.media { return media.name + (media.releaseInfo.map { " \($0.prefix(4))" } ?? "") }
        return item.name
    }

    /// True for names that cannot be a release name: empty, an info hash or other long hex, a UUID, or one long
    /// run of letters and digits without separators ("a8Fk2LmQ9zXw31Pd.mkv").
    public static func looksObfuscated(_ name: String) -> Bool {
        var base = (name as NSString).lastPathComponent
        let ext = (base as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 4, ext.allSatisfy(\.isLetter) || ext.allSatisfy(\.isNumber) || ext.hasPrefix("part") {
            base = (base as NSString).deletingPathExtension
        }
        // `name.part01.rar`, `name.7z.001`
        if base.lowercased().range(of: #"\.(part\d+|7z|rar|r\d{2})$"#, options: .regularExpression) != nil {
            base = (base as NSString).deletingPathExtension
        }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.range(of: #"^[0-9a-fA-F]{16,}$"#, options: .regularExpression) != nil { return true }
        if trimmed.range(of: #"^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil { return true }
        let separators = CharacterSet(charactersIn: " ._-[]()")
        let tokens = trimmed.components(separatedBy: separators).filter { !$0.isEmpty }
        guard tokens.count == 1, let token = tokens.first, token.count >= 12 else { return false }
        if token.range(of: #"(?i)s\d{1,2}e\d{1,3}|(19|20)\d{2}$"#, options: .regularExpression) != nil { return false }
        let hasLetters = token.contains(where: \.isLetter)
        let hasDigits = token.contains(where: \.isNumber)
        let caseChanges = zip(token, token.dropFirst()).filter { $0.isLetter && $1.isLetter && $0.isUppercase != $1.isUppercase }.count
        return (hasLetters && hasDigits) || caseChanges >= 4
    }

    /// One video file's name, or the readable top folder several videos share.
    static func nameFromFiles(_ files: [LibraryFile]) -> String? {
        let videos = files.filter { FileKind.isVideo($0.name) && !FileKind.isSample($0.name) }
        if videos.count == 1, let file = videos.first {
            let name = (file.name as NSString).lastPathComponent
            if !looksObfuscated(name) { return name }
        }
        let folders = videos.map { file -> String? in
            let parts = file.name.split(separator: "/")
            return parts.count > 1 ? String(parts[0]) : nil
        }
        if let folder = folders.first ?? nil, folders.allSatisfy({ $0 == folder }), !looksObfuscated(folder) { return folder }
        return nil
    }
}
