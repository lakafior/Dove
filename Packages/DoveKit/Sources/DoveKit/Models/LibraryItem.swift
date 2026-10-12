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

    public init(
        id: String,
        backend: BackendID,
        name: String,
        size: Int64? = nil,
        status: Status,
        files: [LibraryFile] = [],
        addedAt: Date? = nil
    ) {
        self.id = id
        self.backend = backend
        self.name = name
        self.size = size
        self.status = status
        self.files = files
        self.addedAt = addedAt
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
