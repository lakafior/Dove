import Foundation

struct NzbdavStatus: Decodable {
    let status: Bool?
    let error: String?
}

struct NzbdavAdded: Decodable {
    let nzoIds: [String]?
}

/// `mode=retry` (InfiniDysk): `nzo_id` for one job, `nzo_ids` for several.
struct NzbdavRetried: Decodable {
    let nzoId: String?
    let nzoIds: [String]?
}

struct NzbdavQueueResponse: Decodable {
    struct Queue: Decodable { let slots: [NzbdavQueueSlot]? }
    let queue: Queue?
}

struct NzbdavHistoryResponse: Decodable {
    struct History: Decodable { let slots: [NzbdavHistorySlot]? }
    let history: History?
}

/// `mode=queue` slot. SABnzbd sends numbers as strings; nzbdav follows it, so both are accepted.
struct NzbdavQueueSlot: Decodable {
    let nzoId: String
    let filename: String?
    let cat: String?
    let percentage: LossyDouble?
    let status: String?
    let mb: LossyDouble?

    var libraryItem: LibraryItem {
        let progress = (percentage?.value ?? 0) / 100
        return LibraryItem(
            id: NzbdavItemRef(nzoID: nzoId).id,
            backend: .nzbdav,
            name: filename ?? nzoId,
            size: mb.map { Int64($0.value * 1_048_576) },
            status: status?.lowercased() == "queued" && progress == 0 ? .queued : .downloading(progress: progress)
        )
    }
}

/// `mode=history` slot.
struct NzbdavHistorySlot: Decodable {
    let nzoId: String
    let name: String?
    let nzbName: String?
    let category: String?
    let status: String?
    let bytes: Int64?
    let failMessage: String?
    /// The stored NZB (`GET /api/download-nzb?nzbBlobId=`); missing on jobs from before nzbdav kept them.
    let nzbBlobId: String?
    /// Unix seconds (InfiniDysk); nzbdav sends none.
    let completed: LossyDouble?
    /// The import path (`/mnt/…/completed-symlinks/{category}/{folder}`); its last part is the real folder name.
    let storage: String?

    var jobName: String { name ?? nzbName ?? nzoId }
    var categoryName: String { category?.isEmpty == false ? category! : "uncategorized" }
    var isCompleted: Bool { status?.lowercased() == "completed" }
    var isFailed: Bool { status?.lowercased() == "failed" }

    /// The job's folder: `storage`'s last part when there is one (a second job with the same name gets
    /// "Name (2)"), the job name otherwise.
    var folderName: String {
        if let storage, let last = storage.split(separator: "/").last, !last.isEmpty { return String(last) }
        return jobName
    }

    /// `/content/{category}/{folder}`: where nzbdav mounts the job's files.
    var folderPath: String { "\(NzbdavBackend.contentRoot)/\(categoryName)/\(folderName)" }

    var completedAt: Date? {
        guard let seconds = completed?.value, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    func libraryItem(files: [LibraryFile] = [], addedAt: Date? = nil) -> LibraryItem {
        let state: LibraryItem.Status = switch status?.lowercased() {
        case "completed": .ready
        case "failed": .failed(reason: failMessage?.isEmpty == false ? failMessage! : "failed")
        default: .downloading(progress: 0)
        }
        return LibraryItem(
            id: NzbdavItemRef(nzoID: nzoId).id,
            backend: .nzbdav,
            name: jobName,
            size: bytes,
            status: state,
            files: files,
            addedAt: completedAt ?? addedAt,
            nzbBlobID: nzbBlobId
        )
    }
}

/// A number SABnzbd-style APIs send either as a JSON number or as a string.
struct LossyDouble: Decodable {
    let value: Double

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let text = try? container.decode(String.self), let number = Double(text) {
            value = number
        } else {
            value = 0
        }
    }
}

/// `nzo:<uuid>` for a job (the same ID in the queue and, later, in the history), `dav:<path>` for a job folder
/// under `/content` that has no history entry any more.
enum NzbdavItemRef: Equatable {
    case job(String)
    case folder(String)

    init?(_ id: String) {
        if id.hasPrefix("nzo:"), id.count > 4 {
            self = .job(String(id.dropFirst(4)))
        } else if id.hasPrefix("dav:\(NzbdavBackend.contentRoot)/"), id.count > 4 + NzbdavBackend.contentRoot.count + 1 {
            self = .folder(String(id.dropFirst(4)))
        } else {
            return nil
        }
    }

    init(nzoID: String) {
        self = .job(nzoID)
    }

    var id: String {
        switch self {
        case .job(let nzoID): "nzo:\(nzoID)"
        case .folder(let path): "dav:\(path)"
        }
    }
}
