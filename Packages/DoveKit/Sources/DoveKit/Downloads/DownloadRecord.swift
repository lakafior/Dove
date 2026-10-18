import Foundation

/// One file being downloaded to the device, or already there. Persisted between launches.
///
/// It never stores the download URL: debrid links carry tokens and expire. A retry without
/// resume data asks the backend for a fresh request (`LibraryBackend.downloadRequest`).
public struct DownloadRecord: Codable, Sendable, Identifiable, Hashable {
    public enum State: Codable, Sendable, Hashable {
        case downloading
        case paused
        case finished
        case failed(reason: String)
    }

    public let id: String
    /// The service the file came from; nil for a direct download (`direct`).
    public let backend: BackendID?
    /// Set for files fetched from a direct-download site instead of a service.
    public let direct: DirectDownloadRef?
    public let itemID: LibraryItem.ID
    public let fileID: LibraryFile.ID
    /// The file's name on the service.
    public var name: String
    /// Name in the downloads directory once finished (differs from `name` when that was taken).
    public var localName: String?
    public var state: State
    public var bytesWritten: Int64
    public var totalBytes: Int64?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        backend: BackendID?,
        direct: DirectDownloadRef? = nil,
        itemID: LibraryItem.ID,
        fileID: LibraryFile.ID,
        name: String,
        state: State = .downloading,
        bytesWritten: Int64 = 0,
        totalBytes: Int64? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.backend = backend
        self.direct = direct
        self.itemID = itemID
        self.fileID = fileID
        self.name = name
        self.state = state
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.createdAt = createdAt
    }

    /// 0...1, nil while the size is unknown.
    public var progress: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesWritten) / Double(totalBytes))
    }

    /// Same service, item and file: starting it again reuses this record.
    public func isSameFile(backend: BackendID, itemID: LibraryItem.ID, fileID: LibraryFile.ID) -> Bool {
        self.backend == backend && self.itemID == itemID && self.fileID == fileID
    }
}

public enum DownloadNaming {
    /// A plain file name: the last path component, without characters Files would reject.
    public static func sanitized(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        let cleaned = last
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "download" : cleaned
    }

    /// `name`, or `name (2).ext`, `name (3).ext`… — the first one `isTaken` rejects.
    public static func unique(_ name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
            if !isTaken(candidate) { return candidate }
            number += 1
        }
    }
}
