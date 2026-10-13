import Foundation

/// Every TorBox response is wrapped in this envelope.
struct TorBoxEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let error: String?
    let detail: String?
    let data: T?
}

/// Used for endpoints whose `data` we do not care about. Accepts any JSON value, including null.
struct TorBoxIgnored: Decodable {
    init(from decoder: any Decoder) throws {}
}

/// Torrents and web downloads share this shape in `mylist`.
struct TorBoxTransfer: Decodable {
    let id: Int
    let hash: String?
    let name: String?
    let size: Int64?
    let progress: Double?
    let downloadState: String?
    let downloadFinished: Bool?
    let downloadPresent: Bool?
    let createdAt: String?
    let files: [TorBoxFile]?
}

struct TorBoxFile: Decodable {
    let id: Int
    let name: String?
    let shortName: String?
    let size: Int64?
}

struct TorBoxCachedItem: Decodable {
    let hash: String?
}

struct TorBoxCreateResult: Decodable {
    let torrentId: Int?
    let webdownloadId: Int?
    /// Set instead of the ID above when the account has no free slot and TorBox queues the request.
    let queuedId: Int?
    /// `usenet/createusenetdownload`; the SDK types it as a string, so both are accepted.
    let usenetdownloadId: LossyInt?
    let hash: String?
}

/// An ID TorBox may send as a number or as a string.
struct LossyInt: Decodable {
    let value: Int

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
        } else if let text = try? container.decode(String.self), let number = Int(text) {
            value = number
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ID")
        }
    }
}

/// Library item IDs are prefixed so one list can hold torrents and web downloads.
enum TorBoxItemRef: Equatable {
    case torrent(Int)
    case webDownload(Int)
    /// Waiting for a free slot. Not listed by `mylist`; TorBox moves it to torrents or web downloads later.
    case queued(Int)
    /// An NZB job (`usenet/…`), with a Usenet plan.
    case usenet(Int)

    init?(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        switch parts[0] {
        case "torrent": self = .torrent(number)
        case "webdl": self = .webDownload(number)
        case "queued": self = .queued(number)
        case "usenet": self = .usenet(number)
        default: return nil
        }
    }

    var id: String {
        switch self {
        case .torrent(let n): "torrent:\(n)"
        case .webDownload(let n): "webdl:\(n)"
        case .queued(let n): "queued:\(n)"
        case .usenet(let n): "usenet:\(n)"
        }
    }
}

extension TorBoxTransfer {
    func libraryItem(ref: TorBoxItemRef) -> LibraryItem {
        LibraryItem(
            id: ref.id,
            backend: .torBox,
            name: name ?? hash ?? ref.id,
            size: size,
            status: status,
            files: (files ?? []).map {
                LibraryFile(id: String($0.id), name: $0.shortName ?? $0.name ?? "file \($0.id)", size: $0.size)
            },
            addedAt: createdAt.flatMap(APIDate.parse),
            // Web downloads carry a hash of their URL, not a torrent's.
            infoHash: ref == .torrent(id) ? hash : nil
        )
    }

    var status: LibraryItem.Status {
        let state = downloadState?.lowercased() ?? ""
        if state.contains("error") || state.contains("failed") || state.contains("no seeds") {
            return .failed(reason: downloadState ?? "error")
        }
        if downloadFinished == true && downloadPresent != false {
            return .ready
        }
        if state.contains("queued") {
            return .queued
        }
        return .downloading(progress: progress ?? 0)
    }
}
