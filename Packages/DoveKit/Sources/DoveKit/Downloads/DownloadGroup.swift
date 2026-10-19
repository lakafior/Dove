import Foundation

/// Files of one release in the Downloads list: an album or an audiobook's parts a plugin returned (`id#0`,
/// `id#1`…), or several files of one service item. One row for all of them instead of a row per file.
public struct DownloadGroup: Identifiable, Sendable, Hashable {
    public let id: String
    public var records: [DownloadRecord]

    /// Plugin files of one result, or files of one service item; nil for a file that stands alone.
    public static func key(of record: DownloadRecord) -> String? {
        if let plugin = record.plugin {
            guard let hash = plugin.fileID.lastIndex(of: "#") else { return nil }
            return "plugin:\(plugin.pluginID):\(plugin.fileID[..<hash])"
        }
        if let backend = record.backend { return "item:\(backend.rawValue)/\(record.itemID)" }
        return nil
    }

    /// Records in their order, files of one release together as one group where there are two or more; the
    /// group sits where its first file was.
    public static func make(_ records: [DownloadRecord]) -> [DownloadGroup] {
        var groups: [DownloadGroup] = []
        var index: [String: Int] = [:]
        for record in records {
            if let key = key(of: record), let at = index[key] {
                groups[at].records.append(record)
            } else if let key = key(of: record) {
                index[key] = groups.count
                groups.append(DownloadGroup(id: key, records: [record]))
            } else {
                groups.append(DownloadGroup(id: "record:\(record.id)", records: [record]))
            }
        }
        // A key with one file is that file's own row.
        return groups.map { $0.records.count == 1 ? DownloadGroup(id: "record:\($0.records[0].id)", records: $0.records) : $0 }
    }

    public var isSingle: Bool { records.count == 1 }

    /// The release's folder (`Audiobooks/Author/Title` → "Title"), else the first file's name.
    public var title: String {
        if let folder = records.first?.subfolder?.split(separator: "/").last { return String(folder) }
        let first = records.first.map { $0.localName ?? $0.name } ?? ""
        return records.count > 1 ? "\(first) and \(records.count - 1) more" : first
    }

    public var bytesWritten: Int64 { records.reduce(0) { $0 + $1.bytesWritten } }

    /// Known only when every file's size is.
    public var totalBytes: Int64? {
        let sizes = records.compactMap(\.totalBytes)
        return sizes.count == records.count ? sizes.reduce(0, +) : nil
    }

    public var progress: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(bytesWritten) / Double(totalBytes))
    }

    /// The least finished state: failed, then downloading, then paused, else finished.
    public var state: DownloadRecord.State {
        let states = records.map(\.state)
        for state in states { if case .failed = state { return state } }
        if states.contains(.downloading) { return .downloading }
        if states.contains(.paused) { return .paused }
        return .finished
    }

    public var finishedCount: Int { records.filter { $0.state == .finished }.count }
}
