import Foundation

/// Where an entry sits in the library tree that the Files app shows (the `DoveFiles` extension):
/// Dove › service › item › (folders from the file paths) › file.
public enum LibraryNodeID: Hashable, Sendable {
    case root
    case backend(BackendID)
    case item(BackendID, LibraryItem.ID)
    /// A folder inside an item, from file names with slashes (nzbdav jobs, packs with "Extras/").
    case folder(BackendID, LibraryItem.ID, path: String)
    case file(BackendID, LibraryItem.ID, LibraryFile.ID)

    public var backend: BackendID? {
        switch self {
        case .root: nil
        case .backend(let backend), .item(let backend, _), .folder(let backend, _, _), .file(let backend, _, _): backend
        }
    }

    /// Kind letter plus percent-encoded parts, so item and file IDs may hold any character (nzbdav uses paths).
    public var rawValue: String {
        let parts: [String] = switch self {
        case .root: ["r"]
        case .backend(let backend): ["b", backend.rawValue]
        case .item(let backend, let item): ["i", backend.rawValue, item]
        case .folder(let backend, let item, let path): ["d", backend.rawValue, item, path]
        case .file(let backend, let item, let file): ["f", backend.rawValue, item, file]
        }
        return parts.map(Self.encode).joined(separator: "/")
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false).map { $0.removingPercentEncoding }
        guard let kind = parts.first ?? nil, !parts.contains(nil) else { return nil }
        let rest = parts.dropFirst().compactMap { $0 }
        if kind == "r", rest.isEmpty { self = .root; return }
        guard let first = rest.first, let backend = BackendID(rawValue: first) else { return nil }
        switch (kind, rest.count) {
        case ("b", 1): self = .backend(backend)
        case ("i", 2): self = .item(backend, rest[1])
        case ("d", 3): self = .folder(backend, rest[1], path: rest[2])
        case ("f", 3): self = .file(backend, rest[1], rest[2])
        default: return nil
        }
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))

    private static func encode(_ part: String) -> String {
        part.addingPercentEncoding(withAllowedCharacters: allowed) ?? part
    }
}

/// One entry in the Files tree: a folder or a file with the metadata Files shows.
public struct LibraryNode: Identifiable, Sendable, Hashable {
    public let id: LibraryNodeID
    public let parent: LibraryNodeID
    public var name: String
    public var isFolder: Bool
    public var size: Int64?
    public var date: Date?

    public init(id: LibraryNodeID, parent: LibraryNodeID, name: String, isFolder: Bool, size: Int64? = nil, date: Date? = nil) {
        self.id = id
        self.parent = parent
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.date = date
    }

    /// Changes when Files must refresh the entry (rename, move). Files never change content on a service.
    /// Bump `schema` when what Files derives from a node changes (capabilities), so known entries refresh.
    public var metadataVersion: String {
        "\(Self.schema)|\(parent.rawValue)|\(name)|\(size.map(String.init) ?? "-")"
    }

    static let schema = 4

    public var contentVersion: String {
        isFolder ? "folder" : "\(id.rawValue)|\(size.map(String.init) ?? "-")"
    }

    /// Everything inside an item must be deletable too: Files refuses to delete a folder whose known
    /// contents are not. Deleting just a file or subfolder is refused by the extension, and it comes back.
    public var isDeletable: Bool {
        switch id {
        case .item, .folder, .file: true
        case .root, .backend: false
        }
    }
}

/// File names Files accepts: no slashes, nothing empty, and unique within a folder.
enum NodeNaming {
    static func clean(_ name: String) -> String {
        let trimmed = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." || trimmed == ".." ? "Untitled" : trimmed
    }

    /// Gives every entry a name no sibling shares (ignoring case), adding " (2)", " (3)"… before the extension.
    /// Entries are taken in key order, so the same list always gets the same names.
    static func unique<Key: Comparable>(_ entries: [(key: Key, name: String, isFolder: Bool)]) -> [Key: String] {
        var taken: Set<String> = []
        var result: [Key: String] = [:]
        for entry in entries.sorted(by: { $0.key < $1.key }) {
            let base = clean(entry.name)
            var name = base
            var counter = 2
            while taken.contains(name.lowercased()) {
                name = numbered(base, counter, isFolder: entry.isFolder)
                counter += 1
            }
            taken.insert(name.lowercased())
            result[entry.key] = name
        }
        return result
    }

    private static func numbered(_ name: String, _ number: Int, isFolder: Bool) -> String {
        let ext = (name as NSString).pathExtension
        guard !isFolder, !ext.isEmpty, ext.count <= 5 else { return "\(name) (\(number))" }
        return "\((name as NSString).deletingPathExtension) (\(number)).\(ext)"
    }
}
