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

/// Where a file goes when the user gets it: downloaded (to this device or iCloud Drive), or fetched by a
/// service into its cloud (`LibraryBackend.acceptsDirectLinks`). Stored as one string: `device`, `iCloud`,
/// `service:offcloud`, so preferences saved before services were places still read.
public enum FilePlace: Sendable, Hashable, Codable {
    case download(DownloadDestination)
    case service(BackendID)

    public static let device = FilePlace.download(.device)
    public static let iCloud = FilePlace.download(.iCloud)

    public var rawValue: String {
        switch self {
        case .download(let destination): destination.rawValue
        case .service(let backend): "service:\(backend.rawValue)"
        }
    }

    public init?(rawValue: String) {
        if let destination = DownloadDestination(rawValue: rawValue) {
            self = .download(destination)
        } else if rawValue.hasPrefix("service:"), let backend = BackendID(rawValue: String(rawValue.dropFirst(8))) {
            self = .service(backend)
        } else {
            return nil
        }
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let place = FilePlace(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown place \(raw)"))
        }
        self = place
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var displayName: String {
        switch self {
        case .download(let destination): destination.displayName
        case .service(let backend): backend.displayName
        }
    }
}

/// The default place per content kind: books, audiobooks and music to iCloud Drive (read and played on every
/// device, small enough for iCloud), everything else (video, software) to the device.
public struct DownloadDestinations: Codable, Sendable, Hashable {
    /// The user's choices by `ContentKind.rawValue`; kinds not listed take `standard(for:)`. Values read as
    /// `FilePlace`; an unknown one (a newer build's) falls back to the default.
    public var chosen: [String: FilePlace] = [:]

    public init(chosen: [String: FilePlace] = [:]) {
        self.chosen = chosen
    }

    enum CodingKeys: String, CodingKey { case chosen }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? container.decodeIfPresent([String: String].self, forKey: .chosen)) ?? [:]
        chosen = raw.compactMapValues(FilePlace.init(rawValue:))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chosen.mapValues(\.rawValue), forKey: .chosen)
    }

    public func place(for kind: ContentKind) -> FilePlace {
        chosen[kind.rawValue] ?? Self.standard(for: kind)
    }

    public mutating func set(_ place: FilePlace, for kind: ContentKind) {
        chosen[kind.rawValue] = place == Self.standard(for: kind) ? nil : place
    }

    public static func standard(for kind: ContentKind) -> FilePlace {
        switch kind {
        case .books, .audiobooks, .music: .iCloud
        case .video, .software, .adult, .other: .device
        }
    }
}

/// Which plugin, and which of its files, a download came from: enough to ask the plugin for a fresh link
/// (links expire). Several files of one item carry `id#index`.
public struct PluginFileRef: Codable, Sendable, Hashable {
    public var pluginID: String
    public var fileID: String

    public init(pluginID: String, fileID: String) {
        self.pluginID = pluginID
        self.fileID = fileID
    }

    enum CodingKeys: String, CodingKey {
        case pluginID, fileID
        // Records written before plugins replaced direct downloads: `sourceID` "plugin:<id>", `md5` the file id.
        case sourceID, md5
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let pluginID = try c.decodeIfPresent(String.self, forKey: .pluginID) {
            self.pluginID = pluginID
            fileID = try c.decode(String.self, forKey: .fileID)
        } else {
            let source = try c.decode(String.self, forKey: .sourceID)
            pluginID = source.hasPrefix("plugin:") ? String(source.dropFirst("plugin:".count)) : source
            fileID = try c.decode(String.self, forKey: .md5)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pluginID, forKey: .pluginID)
        try c.encode(fileID, forKey: .fileID)
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
    /// The service the file came from; nil for a file a plugin found (`plugin`).
    public let backend: BackendID?
    /// Set for files a plugin found (stored under the key `direct`, its name before plugins).
    public let plugin: PluginFileRef?
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
        case id, backend, itemID, fileID, name, localName, state, bytesWritten, totalBytes, createdAt, destination
        case subfolder
        case plugin = "direct"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        backend = try container.decodeIfPresent(BackendID.self, forKey: .backend)
        plugin = try? container.decodeIfPresent(PluginFileRef.self, forKey: .plugin)
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
        plugin: PluginFileRef? = nil,
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
        self.plugin = plugin
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
