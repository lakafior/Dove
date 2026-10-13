import Foundation

/// Identifies a library backend. Debrid services and nzbdav share one model.
public enum BackendID: String, Sendable, Codable, CaseIterable, Identifiable {
    case realDebrid
    case torBox
    case offcloud
    case nzbdav

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realDebrid: "Real-Debrid"
        case .torBox: "TorBox"
        case .offcloud: "Offcloud"
        case .nzbdav: "nzbdav"
        }
    }

    /// Usenet backends get their own segment in the Library tab, because their statuses mean different things.
    public var isUsenet: Bool { self == .nzbdav }
}

/// One entry in a backend's library: a torrent, a hoster download or an NZB job.
public struct LibraryItem: Identifiable, Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case queued
        /// Waits for the user to choose files (see `FileSelecting`).
        case awaitingFileSelection
        case downloading(progress: Double)
        case ready
        case failed(reason: String)
    }

    /// Backend-specific, opaque to the UI (e.g. `torrent:123` for TorBox).
    public let id: String
    public let backend: BackendID
    public var name: String
    public var size: Int64?
    public var status: Status
    public var files: [LibraryFile]
    public var addedAt: Date?
    /// Torrents only, lowercased, when the service tells it (Real-Debrid, TorBox; Offcloud from the magnet it was
    /// added with). Lets the user copy the magnet, add the torrent again or move it to another service.
    public var infoHash: String?

    public init(
        id: String,
        backend: BackendID,
        name: String,
        size: Int64? = nil,
        status: Status,
        files: [LibraryFile] = [],
        addedAt: Date? = nil,
        infoHash: String? = nil
    ) {
        self.id = id
        self.backend = backend
        self.name = name
        self.size = size
        self.status = status
        self.files = files
        self.addedAt = addedAt
        self.infoHash = infoHash.flatMap(InfoHash.normalized)
    }

    /// A magnet with the item's name, for copying or adding elsewhere. Nil without an info hash.
    public var magnet: String? {
        guard let infoHash else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let name = self.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "magnet:?xt=urn:btih:\(infoHash)" + (name.isEmpty ? "" : "&dn=\(name)")
    }
}

/// BitTorrent v1 info hashes: 40 hex characters, or 32 base32 ones in older magnets.
public enum InfoHash {
    /// Lowercased hash, or nil when the text is not one.
    public static func normalized(_ text: String) -> String? {
        let hash = text.lowercased()
        let base32 = Set("abcdefghijklmnopqrstuvwxyz234567")
        let valid = (hash.count == 40 && hash.allSatisfy(\.isHexDigit)) || (hash.count == 32 && hash.allSatisfy(base32.contains))
        return valid ? hash : nil
    }

    /// The hash in a magnet's `xt=urn:btih:` topic.
    public static func fromMagnet(_ magnet: String) -> String? {
        guard magnet.lowercased().hasPrefix("magnet:"),
              let topic = URLComponents(string: magnet)?.queryItems?
                .first(where: { $0.name.lowercased() == "xt" })?.value,
              topic.lowercased().hasPrefix("urn:btih:")
        else { return nil }
        return normalized(String(topic.dropFirst("urn:btih:".count)))
    }
}

public struct LibraryFile: Identifiable, Sendable, Hashable {
    public let id: String
    public var name: String
    public var size: Int64?

    public init(id: String, name: String, size: Int64? = nil) {
        self.id = id
        self.name = name
        self.size = size
    }
}
