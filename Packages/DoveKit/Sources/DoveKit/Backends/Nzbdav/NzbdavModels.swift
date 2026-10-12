import Foundation

struct NzbdavStatus: Decodable {
    let status: Bool?
    let error: String?
}

struct NzbdavAdded: Decodable {
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

    var jobName: String { name ?? nzbName ?? nzoId }
    var categoryName: String { category?.isEmpty == false ? category! : "uncategorized" }
    var isCompleted: Bool { status?.lowercased() == "completed" }

    /// `/content/{category}/{job name}`: where nzbdav mounts the job's files.
    var folderPath: String { "\(NzbdavBackend.contentRoot)/\(categoryName)/\(jobName)" }

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
            addedAt: addedAt
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

/// `nzo:<uuid>`. The same ID covers the job in the queue and, later, in the history.
struct NzbdavItemRef: Equatable {
    let nzoID: String

    init(nzoID: String) {
        self.nzoID = nzoID
    }

    init?(_ id: String) {
        guard id.hasPrefix("nzo:"), id.count > 4 else { return nil }
        nzoID = String(id.dropFirst(4))
    }

    var id: String { "nzo:\(nzoID)" }
}
