import Foundation

/// A folder of the user's shown as a library place: iCloud Drive › Dove, laid out by `LibraryFolderLayout`
/// (`Books/<Author>/<Title>/…`, `Video/<item>/…`). Each work folder (or loose file) is an item, IDs are its path
/// (`folder:Books/Andy Weir/Project Hail Mary`), file IDs paths inside it; the kind comes from the top folder and
/// book names read "Author - Title". Entries at the top that are not kind folders (downloads from before the
/// layout) are items too. Nothing is added here through a service: files arrive as downloads.
///
/// iCloud keeps files it has not downloaded to this device as placeholders (`.Name.epub.icloud`): they are
/// listed under their real name, and `downloadRequest` asks iCloud for the file and waits for it.
public struct FolderBackend: LibraryBackend {
    public let id: BackendID
    public let directory: URL
    /// How long `downloadRequest` waits for iCloud to bring a file down.
    let downloadTimeout: Duration

    public init(id: BackendID = .iCloudDrive, directory: URL, downloadTimeout: Duration = .seconds(120)) {
        self.id = id
        self.directory = directory
        self.downloadTimeout = downloadTimeout
    }

    public var supportedSources: Set<SourceKind> { [] }

    public func validateCredentials() async throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw BackendError.api(message: "\(id.displayName) is not available on this device.")
        }
    }

    public func add(_ source: Source) async throws -> LibraryItem.ID {
        throw BackendError.unsupportedSource(source.kind)
    }

    public func items() async throws -> [LibraryItem] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var items: [LibraryItem] = []
        for (url, name) in Self.entries(of: directory) {
            guard let kind = LibraryFolderLayout.kind(ofFolder: name), Self.isDirectory(url) else {
                items.append(item(at: name, name: LibraryFolderLayout.stripExtension(name), kind: nil))
                continue
            }
            for (entryURL, entry) in Self.entries(of: url) {
                if LibraryFolderLayout.byAuthor(kind), Self.isDirectory(entryURL) {
                    // An author's folder: one item per title in it.
                    for (_, title) in Self.entries(of: entryURL) {
                        let workTitle = LibraryFolderLayout.stripExtension(title)
                        items.append(item(
                            at: "\(name)/\(entry)/\(title)",
                            name: LibraryFolderLayout.itemName(author: entry, title: workTitle),
                            kind: kind
                        ))
                    }
                } else {
                    items.append(item(at: "\(name)/\(entry)", name: LibraryFolderLayout.stripExtension(entry), kind: kind))
                }
            }
        }
        return items.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    }

    /// One item: a folder with every file below it, or a single file.
    private func item(at path: String, name: String, kind: ContentKind?) -> LibraryItem {
        let url = directory.appending(path: path)
        let files: [LibraryFile] = Self.isDirectory(url)
            ? Self.files(in: url)
            : [LibraryFile(id: url.lastPathComponent, name: url.lastPathComponent, size: Self.size(of: Self.onDisk(url)))]
        return LibraryItem(
            id: "folder:\(path)",
            backend: id,
            name: name,
            size: files.compactMap(\.size).reduce(0, +),
            status: .ready,
            files: files,
            addedAt: (try? Self.onDisk(url).resourceValues(forKeys: [.creationDateKey]))?.creationDate,
            kindHint: kind
        )
    }

    public func delete(_ itemID: LibraryItem.ID) async throws {
        let url = try entryURL(itemID)
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        } else {
            // Not downloaded here: remove its placeholder, which deletes it in iCloud.
            let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
            try manager.removeItem(at: placeholder)
        }
    }

    /// A `file://` request for the file, once it is on this device.
    public func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
        let entry = try entryURL(itemID)
        let isFile = !Self.isDirectory(entry) && fileID == entry.lastPathComponent
        guard isFile || !fileID.split(separator: "/").contains("..") else { throw BackendError.notFound }
        let url = isFile ? entry : entry.appending(path: fileID)
        try await ensureLocal(url)
        return URLRequest(url: url)
    }

    /// Asks iCloud for a placeholder's file and waits until it is here.
    func ensureLocal(_ url: URL) async throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { return }
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        guard manager.fileExists(atPath: placeholder.path) else { throw BackendError.notFound }
        try manager.startDownloadingUbiquitousItem(at: url)
        let deadline = ContinuousClock.now + downloadTimeout
        while !manager.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else {
                throw BackendError.api(message: "iCloud has not downloaded \(url.lastPathComponent) yet. Try again in a moment.")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func entryURL(_ itemID: LibraryItem.ID) throws -> URL {
        guard itemID.hasPrefix("folder:") else { throw BackendError.notFound }
        let path = String(itemID.dropFirst("folder:".count))
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // Never outside the folder.
        guard !path.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw BackendError.notFound }
        return directory.appending(path: path)
    }

    /// Visible entries of a folder with their real names (placeholders included), sorted.
    static func entries(of folder: URL) -> [(url: URL, name: String)] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return contents.compactMap { url in
            realName(url.lastPathComponent).map { (folder.appending(path: $0), $0) }
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The URL holding the file here: itself, or its iCloud placeholder.
    static func onDisk(_ url: URL) -> URL {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
    }

    /// `.Name.epub.icloud` → `Name.epub`; other hidden files (`.DS_Store`) → nil.
    static func realName(_ name: String) -> String? {
        if name.hasPrefix("."), name.hasSuffix(".icloud") {
            let real = String(name.dropFirst().dropLast(".icloud".count))
            return real.isEmpty ? nil : real
        }
        return name.hasPrefix(".") ? nil : name
    }

    /// Every file below a folder, paths relative to it, placeholders under their real name.
    static func files(in folder: URL) -> [LibraryFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: []
        ) else { return [] }
        var files: [LibraryFile] = []
        let base = folder.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            var parts = relative.split(separator: "/").map(String.init)
            guard let last = parts.popLast(), let real = realName(last) else { continue }
            let path = (parts + [real]).joined(separator: "/")
            files.append(LibraryFile(id: path, name: path, size: size(of: url)))
        }
        return files.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// The file's size; for a placeholder, the size iCloud reports for the real file.
    static func size(of url: URL) -> Int64? {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, !url.lastPathComponent.hasSuffix(".icloud") {
            return Int64(size)
        }
        return (try? url.resourceValues(forKeys: [.totalFileSizeKey]))?.totalFileSize.map(Int64.init)
    }
}
