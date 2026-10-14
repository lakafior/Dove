import Foundation

/// Response of `POST /cloud`.
struct OffcloudAddResult: Decodable {
    let requestId: String?
    let fileName: String?
    let status: String?
    /// Set instead of a request when the account lacks an add-on (`premium`, `links`, `proxy`, `cloud`, `video`).
    let notAvailable: String?
}

/// Entry of `GET /cloud/history` (active transfers only). Carries no sizes.
struct OffcloudHistoryItem: Decodable {
    let requestId: String
    let fileName: String?
    let status: String?
    /// 0…1 while downloading, nil once finished or failed.
    let progress: Double?
    /// "Downloading…", "Seeding…", or why it failed. May be nil.
    let message: String?
    let createdOn: String?
    /// Not in the 2026-10 docs; kept while the API still sends them (single-file links need `server`).
    let isDirectory: Bool?
    /// Download host prefix: files live at `https://{server}.offcloud.com/cloud/download/{requestId}/{fileName}`.
    let server: String?
    /// What was added: a hoster link, or for magnets `<infohash>.torrent` (older entries: the magnet itself).
    let originalLink: String?
}

/// `GET /cloud/explore/{id}?format=detailed`.
struct OffcloudExplore: Decodable {
    let files: [OffcloudFile]
}

/// A file from `cloud/explore` (detailed) or `cache/download`.
struct OffcloudFile: Decodable {
    let url: String
    /// Slash-delimited path inside the download; its first segment is usually the download's root folder.
    let path: String?
    /// `cache/download` splits the path instead.
    let folder: [String]?
    let filename: String?
    let size: Int64?

    var relativePath: String? {
        if let path { return path }
        guard let filename else { return nil }
        return ((folder ?? []) + [filename]).joined(separator: "/")
    }
}

/// One entry of `POST /cache/info`, in the order of the URLs sent.
struct OffcloudCacheInfo: Decodable {
    let cached: Bool?
}

struct OffcloudRemoveResult: Decodable {
    let success: Bool?
}

struct OffcloudAccountInfo: Decodable {
    let isPremium: Bool?
    let expirationDate: String?
}

/// Library item IDs: everything Offcloud stores is a "cloud" request.
enum OffcloudItemRef: Equatable {
    case cloud(String)

    init?(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, parts[0] == "cloud", !parts[1].isEmpty else { return nil }
        self = .cloud(String(parts[1]))
    }

    var id: String {
        switch self {
        case .cloud(let value): "cloud:\(value)"
        }
    }

    var requestID: String {
        switch self {
        case .cloud(let value): value
        }
    }
}

extension OffcloudHistoryItem {
    func libraryItem(files: [LibraryFile] = []) -> LibraryItem {
        LibraryItem(
            id: OffcloudItemRef.cloud(requestId).id,
            backend: .offcloud,
            name: fileName ?? requestId,
            status: libraryStatus,
            files: files,
            addedAt: createdOn.flatMap(APIDate.parse),
            infoHash: infoHash
        )
    }

    /// From the magnet, or from the `<infohash>.torrent` name Offcloud stores for magnets.
    var infoHash: String? {
        guard let originalLink else { return nil }
        if let hash = InfoHash.fromMagnet(originalLink) { return hash }
        guard originalLink.lowercased().hasSuffix(".torrent"), !originalLink.contains("/") else { return nil }
        return InfoHash.normalized(String(originalLink.dropLast(".torrent".count)))
    }

    var libraryStatus: LibraryItem.Status {
        switch status {
        case "downloaded": .ready
        case "created", "queued", "downloading", nil:
            if let progress, progress > 0 { .downloading(progress: min(progress, 1)) } else { .queued }
        case "error": .failed(reason: message.flatMap { $0.isEmpty ? nil : $0 } ?? "error")
        case let other?: .failed(reason: other)
        }
    }

    /// Direct link for a single-file request (folders go through `cloud/explore`).
    var singleFileURL: URL? {
        guard let server, let fileName,
              let name = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"]))
        else { return nil }
        return URL(string: "https://\(server).offcloud.com/cloud/download/\(requestId)/\(name)")
    }
}

enum OffcloudMagnet {
    /// Offcloud accepts a garbage magnet and leaves it "Loading..." forever, so validate before adding.
    static func hasValidInfoHash(_ magnet: String) -> Bool {
        InfoHash.fromMagnet(magnet) != nil
    }
}
