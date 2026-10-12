import Foundation

/// Serves the library as a folder tree for the Files app (`DoveFiles` extension).
///
/// Dove › one folder per configured service › one folder per ready item › its files (with subfolders when
/// file names carry paths). Only ready items are listed: Files has no way to show a status.
///
/// Files asks for the same entries many times while browsing, so service lists and item details are cached
/// briefly and concurrent requests share one call (Real-Debrid allows 250 requests a minute).
public actor LibraryBrowser {
    private let backends: [any LibraryBackend]
    private let cacheLifetime: TimeInterval
    private let now: @Sendable () -> Date

    private var lists: [BackendID: (date: Date, task: Task<[LibraryItem], any Error>)] = [:]
    private var details: [DetailKey: (date: Date, task: Task<LibraryItem, any Error>)] = [:]

    private struct DetailKey: Hashable {
        let backend: BackendID
        let item: LibraryItem.ID
    }

    public init(backends: [any LibraryBackend], cacheLifetime: TimeInterval = 30, now: @escaping @Sendable () -> Date = Date.init) {
        self.backends = backends
        self.cacheLifetime = cacheLifetime
        self.now = now
    }

    public var configured: [BackendID] { backends.map(\.id) }

    // MARK: - Tree

    public func children(of id: LibraryNodeID) async throws -> [LibraryNode] {
        switch id {
        case .root:
            return backends.map(Self.backendNode)
        case .backend(let backend):
            return try await itemNodes(backend)
        case .item(let backend, let itemID):
            return Self.entries(of: try await detail(backend, itemID), at: [])
        case .folder(let backend, let itemID, let path):
            return Self.entries(of: try await detail(backend, itemID), at: Self.components(path))
        case .file:
            return []
        }
    }

    public func node(_ id: LibraryNodeID) async throws -> LibraryNode {
        switch id {
        case .root:
            return LibraryNode(id: .root, parent: .root, name: "Dove", isFolder: true)
        case .backend(let backend):
            guard let match = backends.first(where: { $0.id == backend }) else { throw BackendError.notFound }
            return Self.backendNode(match)
        case .item(let backend, _):
            guard let match = try await itemNodes(backend).first(where: { $0.id == id }) else { throw BackendError.notFound }
            return match
        case .folder(let backend, let itemID, let path):
            let parentPath = Self.components(path).dropLast()
            let siblings = Self.entries(of: try await detail(backend, itemID), at: Array(parentPath))
            guard let match = siblings.first(where: { $0.id == id }) else { throw BackendError.notFound }
            return match
        case .file(let backend, let itemID, let fileID):
            let item = try await detail(backend, itemID)
            guard let file = item.files.first(where: { $0.id == fileID }) else { throw BackendError.notFound }
            let siblings = Self.entries(of: item, at: Array(Self.components(file.name).dropLast()))
            guard let match = siblings.first(where: { $0.id == id }) else { throw BackendError.notFound }
            return match
        }
    }

    /// Every service and its ready items, fetched fresh: what the Files working set tracks for changes.
    /// Services that fail are reported so their items are not taken as deleted.
    public func topLevel() async -> (nodes: [LibraryNode], failed: Set<BackendID>) {
        lists = [:]
        var nodes = backends.map(Self.backendNode)
        var failed: Set<BackendID> = []
        await withTaskGroup(of: (BackendID, [LibraryNode]?).self) { group in
            for backend in backends.map(\.id) {
                group.addTask { (backend, try? await self.itemNodes(backend)) }
            }
            for await (backend, items) in group {
                if let items { nodes += items } else { failed.insert(backend) }
            }
        }
        return (nodes, failed)
    }

    // MARK: - Actions

    public func downloadRequest(for id: LibraryNodeID) async throws -> URLRequest {
        guard case .file(let backend, let itemID, let fileID) = id else { throw BackendError.notFound }
        return try await self.backend(backend).downloadRequest(itemID: itemID, fileID: fileID)
    }

    /// Deletes an item from its service. Only item folders can be deleted.
    public func delete(_ id: LibraryNodeID) async throws {
        guard case .item(let backend, let itemID) = id else {
            throw BackendError.api(message: "Only whole items can be deleted.")
        }
        try await self.backend(backend).delete(itemID)
        lists[backend] = nil
        details[DetailKey(backend: backend, item: itemID)] = nil
    }

    /// A `.torrent` or `.nzb` dropped into a service folder in Files. Nil for anything else, which Files keeps
    /// on the device without syncing.
    public static func source(fileNamed name: String, data: Data) -> Source? {
        switch (name as NSString).pathExtension.lowercased() {
        case "torrent": .torrentFile(data: data, filename: name)
        case "nzb": .nzbFile(data: data, filename: name)
        default: nil
        }
    }

    /// Adds a dropped file to that service (not through the priority order: the user picked the folder).
    public func add(_ source: Source, to backendID: BackendID) async throws {
        let backend = try backend(backendID)
        guard backend.supports(source) else { throw BackendError.unsupportedSource(source.kind) }
        try await backend.add(source)
        lists[backendID] = nil
    }

    /// Drops cached lists, e.g. when the app says the library changed.
    public func invalidate() {
        lists = [:]
        details = [:]
    }

    // MARK: - Fetching

    private func backend(_ id: BackendID) throws -> any LibraryBackend {
        guard let match = backends.first(where: { $0.id == id }) else { throw BackendError.notFound }
        return match
    }

    private func items(_ backendID: BackendID) async throws -> [LibraryItem] {
        if let cached = lists[backendID], now().timeIntervalSince(cached.date) < cacheLifetime {
            return try await cached.task.value
        }
        let backend = try backend(backendID)
        let task = Task { try await backend.items() }
        lists[backendID] = (now(), task)
        do {
            return try await task.value
        } catch {
            if lists[backendID]?.task == task { lists[backendID] = nil }
            throw error
        }
    }

    /// The item with its files. Lists that already carry files (TorBox, Real-Debrid downloads) save a call.
    private func detail(_ backendID: BackendID, _ itemID: LibraryItem.ID) async throws -> LibraryItem {
        let key = DetailKey(backend: backendID, item: itemID)
        if let cached = details[key], now().timeIntervalSince(cached.date) < cacheLifetime {
            return try await cached.task.value
        }
        if let listed = lists[backendID], now().timeIntervalSince(listed.date) < cacheLifetime,
           let item = try? await listed.task.value.first(where: { $0.id == itemID }), !item.files.isEmpty {
            return item
        }
        let backend = try backend(backendID)
        let task = Task { try await backend.item(itemID) }
        details[key] = (now(), task)
        do {
            return try await task.value
        } catch {
            if details[key]?.task == task { details[key] = nil }
            throw error
        }
    }

    private func itemNodes(_ backend: BackendID) async throws -> [LibraryNode] {
        let ready = try await items(backend).filter { $0.status == .ready }
        let names = NodeNaming.unique(ready.map { (key: $0.id, name: $0.name, isFolder: true) })
        return ready.map { item in
            LibraryNode(
                id: .item(backend, item.id),
                parent: .backend(backend),
                name: names[item.id] ?? NodeNaming.clean(item.name),
                isFolder: true,
                size: item.size,
                date: item.addedAt
            )
        }
    }

    // MARK: - Item contents

    private static func backendNode(_ backend: any LibraryBackend) -> LibraryNode {
        LibraryNode(id: .backend(backend.id), parent: .root, name: backend.id.displayName, isFolder: true)
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// What sits at `path` inside an item: its files, and a folder for every deeper path.
    static func entries(of item: LibraryItem, at path: [String]) -> [LibraryNode] {
        let parent: LibraryNodeID = path.isEmpty
            ? .item(item.backend, item.id)
            : .folder(item.backend, item.id, path: path.joined(separator: "/"))
        var folders: [String: Int64] = [:]
        var files: [LibraryFile] = []
        for file in item.files {
            let parts = components(file.name)
            guard parts.count > path.count, Array(parts.prefix(path.count)) == path else { continue }
            if parts.count == path.count + 1 {
                files.append(file)
            } else {
                folders[parts[path.count], default: 0] += file.size ?? 0
            }
        }
        // "d" sorts before "f": folders keep their names when a file shares one.
        let names = NodeNaming.unique(
            folders.keys.map { (key: "d" + $0, name: $0, isFolder: true) }
                + files.map { (key: "f" + $0.id, name: components($0.name).last ?? $0.name, isFolder: false) }
        )
        let folderNodes = folders.map { name, size in
            LibraryNode(
                id: .folder(item.backend, item.id, path: (path + [name]).joined(separator: "/")),
                parent: parent,
                name: names["d" + name] ?? NodeNaming.clean(name),
                isFolder: true,
                size: size,
                date: item.addedAt
            )
        }
        let fileNodes = files.map { file in
            LibraryNode(
                id: .file(item.backend, item.id, file.id),
                parent: parent,
                name: names["f" + file.id] ?? NodeNaming.clean(file.name),
                isFolder: false,
                size: file.size,
                date: item.addedAt
            )
        }
        return folderNodes.sorted { $0.name < $1.name } + fileNodes.sorted { $0.name < $1.name }
    }
}
