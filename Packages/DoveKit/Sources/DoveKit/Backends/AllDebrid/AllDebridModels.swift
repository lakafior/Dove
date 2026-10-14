import Foundation

/// `{"status": "success", "data": …}` or `{"status": "error", "error": {"code", "message"}}`.
struct AllDebridEnvelope<T: Decodable>: Decodable {
    let status: String
    let data: T?
    let error: AllDebridError?
}

struct AllDebridError: Decodable {
    let code: String?
    let message: String?
}

/// `POST v4/magnet/upload` → `data.magnets`, `POST v4/magnet/upload/file` → `data.files`: one entry per input,
/// each with an `id` or its own `error`.
struct AllDebridUploads: Decodable {
    let magnets: [AllDebridUpload]?
    let files: [AllDebridUpload]?
}

struct AllDebridUpload: Decodable {
    let id: LossyInt?
    let name: String?
    let hash: String?
    let ready: Bool?
    let error: AllDebridError?
}

/// `POST v4.1/magnet/status` → `data.magnets`: a list, or one object when a single `id` is asked for.
struct AllDebridMagnets: Decodable {
    let magnets: [AllDebridMagnet]

    private enum CodingKeys: String, CodingKey { case magnets }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? container.decode([AllDebridMagnet].self, forKey: .magnets) {
            magnets = list
        } else {
            magnets = [try container.decode(AllDebridMagnet.self, forKey: .magnets)]
        }
    }
}

struct AllDebridMagnet: Decodable {
    let id: LossyInt
    let filename: String?
    let size: Int64?
    let status: String?
    let statusCode: Int?
    let downloaded: Int64?
    let hash: String?
    let uploadDate: Int64?

    /// 0 queued, 1–3 downloading / moving / uploading, 4 ready, 5–15 errors (`status` says which).
    var libraryStatus: LibraryItem.Status {
        switch statusCode {
        case 0: .queued
        case 1, 2, 3:
            .downloading(progress: size.flatMap { $0 > 0 ? min(Double(downloaded ?? 0) / Double($0), 1) : nil } ?? 0)
        case 4: .ready
        case .some: .failed(reason: status ?? "Error")
        case nil: .queued
        }
    }

    func libraryItem(files: [LibraryFile] = []) -> LibraryItem {
        LibraryItem(
            id: AllDebridItemRef.magnet(id.value).id,
            backend: .allDebrid,
            name: filename ?? String(id.value),
            size: size,
            status: libraryStatus,
            files: files,
            addedAt: uploadDate.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            infoHash: hash
        )
    }
}

/// `POST v4/magnet/files` → `data.magnets[].files`: a tree of folders (`n`, `e`) and files (`n`, `s`, `l`).
struct AllDebridMagnetFiles: Decodable {
    let magnets: [Entry]

    struct Entry: Decodable {
        let id: LossyInt
        let files: [AllDebridNode]?
        let error: AllDebridError?
    }
}

struct AllDebridNode: Decodable {
    let n: String
    let s: Int64?
    let l: String?
    let e: [AllDebridNode]?

    /// Every file under this node with its path, depth first.
    func flattened(prefix: String = "") -> [(path: String, size: Int64?, link: String)] {
        if let children = e {
            return children.flatMap { $0.flattened(prefix: prefix + n + "/") }
        }
        guard let l else { return [] }
        return [(prefix + n, s, l)]
    }
}

/// `POST v4/link/unlock` → `data`: the direct `link`, or a `delayed` ID to poll while the hoster prepares it.
struct AllDebridUnlocked: Decodable {
    let link: String?
    let filename: String?
    let filesize: Int64?
    let host: String?
    let delayed: LossyInt?
}

/// `POST v4/link/delayed` → `data`: `status` 1 still working, 2 ready (`link`), 3 failed.
struct AllDebridDelayed: Decodable {
    let status: Int
    let link: String?
}

/// `POST v4/link/redirector` → `data.links`: the files behind a folder or redirector link.
struct AllDebridRedirected: Decodable {
    let links: [String]
}

/// `GET v4/user/links` → `data.links`: hoster links the user saved.
struct AllDebridSavedLinks: Decodable {
    let links: [AllDebridSavedLink]
}

struct AllDebridSavedLink: Decodable {
    let link: String
    let filename: String?
    let size: Int64?
    let date: Int64?
    let host: String?

    var libraryItem: LibraryItem {
        let name = filename ?? URL(string: link)?.lastPathComponent ?? link
        return LibraryItem(
            id: AllDebridItemRef.link(link).id,
            backend: .allDebrid,
            name: name,
            size: size,
            status: .ready,
            files: [LibraryFile(id: "0", name: name, size: size)],
            addedAt: date.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

/// `GET v4/user` → `data.user`. `premiumUntil` is 0 without premium, sometimes a string.
struct AllDebridUserData: Decodable {
    let user: User

    struct User: Decodable {
        let isPremium: Bool?
        let premiumUntil: LossyInt?
    }
}

/// `GET v4/hosts` → `data.hosts`: keyed by hoster, with `domains` and `status` (working lately).
struct AllDebridHosts: Decodable {
    let hosts: [String: Host]

    struct Host: Decodable {
        let name: String?
        let domains: [String]?
        let status: Bool?
    }
}

/// Library item IDs: magnets by number, saved hoster links by the link itself (AllDebrid has no other ID for them).
enum AllDebridItemRef: Equatable {
    case magnet(Int)
    case link(String)

    init?(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "magnet":
            guard let number = Int(parts[1]) else { return nil }
            self = .magnet(number)
        case "link": self = .link(String(parts[1]))
        default: return nil
        }
    }

    var id: String {
        switch self {
        case .magnet(let number): "magnet:\(number)"
        case .link(let link): "link:\(link)"
        }
    }
}
