import Foundation

/// Every Premiumize answer: `status` "success" or "error" (with `message` and `code`), mostly with HTTP 200.
struct PremiumizeEnvelope: Decodable {
    let status: String?
    let message: String?
    let code: String?
}

/// Entry of `GET transfer/list`. `folder_id`/`file_id` point at what a finished transfer put in the cloud: its
/// own folder for several files, the file for one.
struct PremiumizeTransfer: Decodable {
    let id: String
    let name: String?
    let status: String?
    let progress: Double?
    let message: String?
    let src: String?
    let folderId: String?
    let fileId: String?

    var isFinished: Bool { status == "finished" || status == "seeding" }

    var libraryStatus: LibraryItem.Status {
        switch status {
        case "finished", "seeding": .ready
        case "running": .downloading(progress: min(max(progress ?? 0, 0), 1))
        case "queued", "waiting": .queued
        case "error", "timeout", "banned", "deleted":
            .failed(reason: message.flatMap { $0.isEmpty ? nil : $0 } ?? (status ?? "error").capitalized)
        default: .queued
        }
    }

    func libraryItem(files: [LibraryFile] = []) -> LibraryItem {
        LibraryItem(
            id: PremiumizeItemRef.transfer(id).id,
            backend: .premiumize,
            name: name ?? message ?? id,
            status: libraryStatus,
            files: files,
            infoHash: src.flatMap(InfoHash.fromMagnet)
        )
    }
}

struct PremiumizeTransferList: Decodable {
    let transfers: [PremiumizeTransfer]
}

struct PremiumizeCreated: Decodable {
    let id: String?
    let name: String?
}

/// `GET folder/list`: a folder's direct children.
struct PremiumizeFolder: Decodable {
    let content: [PremiumizeFolderItem]
    let name: String?
    let folderId: String?
}

struct PremiumizeFolderItem: Decodable {
    let id: String
    let name: String
    let type: String
    let size: Int64?
    let createdAt: Int64?
    let link: String?

    var isFolder: Bool { type == "folder" }
    var addedAt: Date? { createdAt.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

/// `GET item/details`: one file.
struct PremiumizeItemDetails: Decodable {
    let id: String
    let name: String?
    let size: Int64?
    let link: String?
}

struct PremiumizeAccount: Decodable {
    /// Unix seconds; null or 0 without premium.
    let premiumUntil: Int64?
}

/// `GET cache/check`: answers in the order asked.
struct PremiumizeCacheCheck: Decodable {
    let response: [Bool]
}

/// `GET services/list`: hosters for direct downloads (`directdl`), with `aliases` mapping a domain to others.
struct PremiumizeServices: Decodable {
    let directdl: [String]?
    let aliases: [String: [String]]?
}

/// Library item IDs. Transfers are what Dove adds; the cloud's root holds what they became (and anything else
/// the user put there).
enum PremiumizeItemRef: Equatable {
    case transfer(String)
    case folder(String)
    case file(String)

    init?(_ id: String) {
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let value = String(parts[1])
        switch parts[0] {
        case "transfer": self = .transfer(value)
        case "folder": self = .folder(value)
        case "file": self = .file(value)
        default: return nil
        }
    }

    var id: String {
        switch self {
        case .transfer(let value): "transfer:\(value)"
        case .folder(let value): "folder:\(value)"
        case .file(let value): "file:\(value)"
        }
    }
}
