import Foundation

/// A local notification about phone downloads. No push: the background `URLSession` wakes the app when a file
/// finishes, and the app posts these then.
public struct DownloadNotice: Sendable, Hashable {
    /// The request identifier: a newer notice about the same download replaces the older one.
    public let id: String
    public let title: String
    public let body: String
    /// Groups notices in Notification Center.
    public let thread: String
}

public enum DownloadNotices {
    public static let thread = "downloads"

    /// A download finished or failed. Files of a download-only job only report failures: the job tells when
    /// everything is on the device.
    public static func notice(for record: DownloadRecord, job: DownloadJob?) -> DownloadNotice? {
        let name = (record.name as NSString).lastPathComponent
        switch record.state {
        case .finished:
            guard job == nil else { return nil }
            let size = record.totalBytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            return DownloadNotice(id: "download:\(record.id)", title: "Downloaded", body: name + size, thread: thread)
        case .failed(let reason):
            let title = job.map { "Download only: \($0.name)" } ?? "Download failed"
            return DownloadNotice(id: "download:\(record.id)", title: title, body: "\(name): \(reason)", thread: thread)
        case .downloading, .paused:
            return nil
        }
    }

    /// A download-only job is done (or stopped).
    public static func notice(for job: DownloadJob, outcome: DownloadJob.Outcome) -> DownloadNotice {
        switch outcome {
        case .finished(let files):
            let count = files == 1 ? "" : "\(files) files · "
            return DownloadNotice(
                id: "job:\(job.id)",
                title: "On your iPhone",
                body: "\(job.name)\n\(count)removed from \(job.backend.displayName)",
                thread: thread
            )
        case .failed(let reason):
            return DownloadNotice(id: "job:\(job.id)", title: "Download only stopped", body: "\(job.name): \(reason)", thread: thread)
        }
    }
}

/// What the Live Activity shows: every phone download since it started, as one bar. Its `ContentState`.
public struct DownloadActivitySummary: Codable, Sendable, Hashable {
    /// Downloads still running.
    public var active: Int
    /// Finished since the activity started.
    public var finished: Int
    public var failed: Int
    public var bytesWritten: Int64
    /// Nil while a running download does not know its size.
    public var totalBytes: Int64?
    /// The running download with the most left, to name on the Lock Screen.
    public var current: String?

    public init(active: Int = 0, finished: Int = 0, failed: Int = 0, bytesWritten: Int64 = 0, totalBytes: Int64? = nil, current: String? = nil) {
        self.active = active
        self.finished = finished
        self.failed = failed
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.current = current
    }

    /// - Parameter covering: downloads the activity has shown running. Settled ones count only if listed, so older
    ///   finished files stay out and a file that finishes does not leave the totals (the bar never jumps back).
    public init(records: [DownloadRecord], covering: Set<DownloadRecord.ID>) {
        self.init()
        var sizeKnown = true
        var total: Int64 = 0
        var largestLeft: Int64 = -1
        for record in records {
            switch record.state {
            case .downloading:
                active += 1
                bytesWritten += record.bytesWritten
                if let size = record.totalBytes { total += size } else { sizeKnown = false }
                let left = (record.totalBytes ?? .max) - record.bytesWritten
                if left > largestLeft {
                    largestLeft = left
                    current = (record.name as NSString).lastPathComponent
                }
            case .finished where covering.contains(record.id):
                finished += 1
                bytesWritten += record.bytesWritten
                total += record.totalBytes ?? record.bytesWritten
            case .failed where covering.contains(record.id):
                failed += 1
            default:
                break
            }
        }
        totalBytes = sizeKnown ? total : nil
    }

    public var isDone: Bool { active == 0 }

    /// 0…1, nil when a size is unknown.
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesWritten) / Double(totalBytes))
    }

    /// "2 downloading · 1 done", "3 files downloaded", "1 failed".
    public var status: String {
        if isDone {
            let done = finished == 1 ? "1 file downloaded" : "\(finished) files downloaded"
            return failed == 0 ? done : finished == 0 ? "\(failed) failed" : "\(done) · \(failed) failed"
        }
        var parts = ["\(active) downloading"]
        if finished > 0 { parts.append("\(finished) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    /// Worth pushing to ActivityKit (its update budget is small): a download started or ended, or the bar moved
    /// a whole percent.
    public func differs(from other: DownloadActivitySummary) -> Bool {
        if active != other.active || finished != other.finished || failed != other.failed || current != other.current { return true }
        switch (fraction, other.fraction) {
        case let (a?, b?): return abs(a - b) >= 0.01
        case (nil, nil): return abs(bytesWritten - other.bytesWritten) >= 50_000_000
        default: return true
        }
    }
}
