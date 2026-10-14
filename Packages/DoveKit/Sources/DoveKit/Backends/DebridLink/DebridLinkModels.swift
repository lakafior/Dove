import Foundation

/// Every v2 response: `{"success": true, "value": …, "pagination": {…}}` or `{"success": false, "error": "badToken"}`.
struct DebridLinkEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let error: String?
    let value: T?
    let pagination: DebridLinkPagination?
}

struct DebridLinkPagination: Decodable {
    /// -1 on the last page.
    let next: Int?
}

/// Endpoints whose `value` Dove does not read.
struct DebridLinkIgnored: Decodable {
    init(from decoder: any Decoder) throws {}
}

/// `seedbox/list`, `seedbox/add`.
struct DebridLinkTorrent: Decodable {
    let id: String
    let name: String?
    /// Unix seconds.
    let created: Double?
    let hashString: String?
    let wait: Bool?
    /// `status`: 0 paused, 1 queued, 2 verifying, 4 downloading, 8 seeding, 100 finished.
    let state: Int?
    let totalSize: Int64?
    let downloadPercent: Double?
    /// Many files come as one ZIP entry here; `seedbox/list?ids=` lists them all.
    let isZip: Bool?
    let files: [DebridLinkFile]?

    enum CodingKeys: String, CodingKey {
        case id, name, created, hashString, wait, totalSize, downloadPercent, isZip, files
        case state = "status"
    }
}

struct DebridLinkFile: Decodable {
    let id: String
    let name: String?
    let size: Int64?
    let downloadUrl: String?
    let downloadPercent: Double?
}

/// `downloader/list`, `downloader/add` (a hoster link).
struct DebridLinkLink: Decodable {
    let id: String
    let name: String?
    let url: String?
    let downloadUrl: String?
    let expired: Bool?
    let size: Int64?
    let created: Double?
    let isProcessing: Bool?
}

/// `downloader/add` answers with one link, or a list for a folder.
struct DebridLinkLinks: Decodable {
    let links: [DebridLinkLink]

    init(from decoder: any Decoder) throws {
        if let list = try? [DebridLinkLink](from: decoder) {
            links = list
        } else {
            links = [try DebridLinkLink(from: decoder)]
        }
    }
}

/// `account/infos`.
struct DebridLinkAccount: Decodable {
    /// 0 free, 1 premium, 2 lifetime premium.
    let accountType: Int?
    /// Seconds of premium left, 0 for free accounts.
    let premiumLeft: Double?
}

/// Library item IDs: `torrent:<id>` (seedbox) and `link:<id>` (downloader).
enum DebridLinkItemRef: Equatable {
    case torrent(String)
    case link(String)

    init?(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "torrent": self = .torrent(parts[1])
        case "link": self = .link(parts[1])
        default: return nil
        }
    }

    var id: String {
        switch self {
        case .torrent(let id): "torrent:\(id)"
        case .link(let id): "link:\(id)"
        }
    }
}

extension DebridLinkTorrent {
    func libraryItem() -> LibraryItem {
        LibraryItem(
            id: DebridLinkItemRef.torrent(id).id,
            backend: .debridLink,
            name: name ?? hashString ?? id,
            size: totalSize,
            status: status,
            // A ZIP stand-in is no file of the torrent; `item(_:)` asks for the real list.
            files: isZip == true ? [] : (files ?? []).map(\.libraryFile),
            addedAt: created.map { Date(timeIntervalSince1970: $0) },
            infoHash: hashString
        )
    }

    /// Seeding and finished torrents are ready once every wanted file is there; a paused or queued one that
    /// already has everything is ready too.
    var status: LibraryItem.Status {
        let percent = downloadPercent ?? 0
        if percent >= 100 { return .ready }
        switch state ?? 0 {
        case 2, 4, 8, 100: return .downloading(progress: percent / 100)
        default: return .queued
        }
    }
}

extension DebridLinkFile {
    var libraryFile: LibraryFile {
        LibraryFile(id: id, name: name ?? id, size: size)
    }
}

extension DebridLinkLink {
    func libraryItem() -> LibraryItem {
        LibraryItem(
            id: DebridLinkItemRef.link(id).id,
            backend: .debridLink,
            name: name ?? url ?? id,
            size: size,
            status: isProcessing == true ? .downloading(progress: 0) : .ready,
            files: [LibraryFile(id: id, name: name ?? id, size: size)],
            addedAt: created.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
