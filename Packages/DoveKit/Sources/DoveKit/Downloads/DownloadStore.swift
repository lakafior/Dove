import Foundation

/// Download records (`downloads.json`) and resume data (`resume/<id>`) in one directory.
///
/// Resume data embeds the original request, debrid tokens and nzbdav's Basic Auth included,
/// so it is written with file protection and removed as soon as it is used.
public struct DownloadStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var recordsURL: URL { directory.appending(path: "downloads.json") }
    private var resumeDirectory: URL { directory.appending(path: "resume", directoryHint: .isDirectory) }

    public func load() -> [DownloadRecord] {
        guard let data = try? Data(contentsOf: recordsURL),
              let records = try? JSONDecoder().decode([DownloadRecord].self, from: data)
        else { return [] }
        return records
    }

    public func save(_ records: [DownloadRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        write(data, to: recordsURL)
    }

    public func resumeData(for id: DownloadRecord.ID) -> Data? {
        try? Data(contentsOf: resumeURL(id))
    }

    public func setResumeData(_ data: Data?, for id: DownloadRecord.ID) {
        if let data {
            write(data, to: resumeURL(id))
        } else {
            try? FileManager.default.removeItem(at: resumeURL(id))
        }
    }

    private func resumeURL(_ id: DownloadRecord.ID) -> URL {
        resumeDirectory.appending(path: id)
    }

    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}
