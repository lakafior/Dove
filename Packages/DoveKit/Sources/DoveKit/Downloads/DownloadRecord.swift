import Foundation

/// Where a downloaded file is kept.
public enum DownloadDestination: String, Codable, Sendable, Hashable, CaseIterable {
    /// Dove's Documents on this device (Files › On My iPhone › Dove).
    case device
    /// iCloud Drive › Dove: on the user's other devices too, and listed in the Library as a place.
    case iCloud

    public var displayName: String {
        switch self {
        case .device: "This iPhone"
        case .iCloud: "iCloud Drive"
        }
    }
}

/// The default place per content kind: books, audiobooks and music to iCloud Drive (read and played on every
/// device, small enough for iCloud), everything else (video, software) to the device.
public struct DownloadDestinations: Codable, Sendable, Hashable {
    /// The user's choices by `ContentKind.rawValue`; kinds not listed take `standard(for:)`.
    public var chosen: [String: DownloadDestination] = [:]

    public init(chosen: [String: DownloadDestination] = [:]) {
        self.chosen = chosen
    }

    public func destination(for kind: ContentKind) -> DownloadDestination {
        chosen[kind.rawValue] ?? Self.standard(for: kind)
    }

    public mutating func set(_ destination: DownloadDestination, for kind: ContentKind) {
        chosen[kind.rawValue] = destination == Self.standard(for: kind) ? nil : destination
    }

    public static func standard(for kind: ContentKind) -> DownloadDestination {
        switch kind {
        case .books, .audiobooks, .music: .iCloud
        case .video, .software, .adult, .other: .device
        }
    }
}

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
    /// Where the file goes (and is, once finished).
    public var destination: DownloadDestination
    /// Folder inside the destination (`Books/Andy Weir/Project Hail Mary`, `LibraryFolderLayout`); nil = its root.
    public var subfolder: String?

    enum CodingKeys: String, CodingKey {
        case id, backend, direct, itemID, fileID, name, localName, state, bytesWritten, totalBytes, createdAt, destination
        case subfolder
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        backend = try container.decodeIfPresent(BackendID.self, forKey: .backend)
        direct = try container.decodeIfPresent(DirectDownloadRef.self, forKey: .direct)
        itemID = try container.decode(LibraryItem.ID.self, forKey: .itemID)
        fileID = try container.decode(LibraryFile.ID.self, forKey: .fileID)
        name = try container.decode(String.self, forKey: .name)
        localName = try container.decodeIfPresent(String.self, forKey: .localName)
        state = try container.decode(State.self, forKey: .state)
        bytesWritten = try container.decode(Int64.self, forKey: .bytesWritten)
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // Records from before destinations were all on the device.
        destination = try container.decodeIfPresent(DownloadDestination.self, forKey: .destination) ?? .device
        subfolder = try container.decodeIfPresent(String.self, forKey: .subfolder)
    }

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
        createdAt: Date = .now,
        destination: DownloadDestination = .device,
        subfolder: String? = nil
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
        self.destination = destination
        self.subfolder = subfolder
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
