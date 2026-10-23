import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// The releases the library holds for a title, book, album or game, as a Finder-like table: each release opens onto
/// its files (disclosure triangles). Every action of the iPhone's item screen is here: a release's in its row's ⋯
/// and its context menu (download, choose files, copy magnet, refresh, reinsert, send on, move, change type,
/// delete), a file's as row buttons and its context menu (play, play in…, download, Save to iCloud Drive, copy link,
/// Show in Finder). Shown on item pages and as the Releases tab of series and albums.
struct MacHeldReleases: View {
    @Environment(AppModel.self) private var model
    let items: [ShelfItem]

    @State private var store = ReleaseStore()
    @State private var selection = Set<ReleaseNode.ID>()

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("Nothing left here", systemImage: "tray",
                                       description: Text("Its releases are no longer in the library."))
            } else {
                releaseTable
            }
        }
        .sheet(item: $store.choosingFiles) { item in
            if let backend = model.backend(item.item.backend) as? any FileSelecting {
                FileSelectionView(backend: backend, itemID: item.item.id) {
                    await model.library.refresh(using: model, afterChange: true)
                    await store.loadFiles(items, using: model)
                }
                .frame(minWidth: 520, minHeight: 480)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !store.pendingDelete.isEmpty }, set: { if !$0 { store.pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                let items = store.pendingDelete
                Task { await model.library.delete(items, using: model) }
            }
        } message: {
            Text("It is deleted on the service that holds it.")
        }
        .confirmationDialog("Add this again?",
                            isPresented: Binding(get: { store.pendingReinsert != nil }, set: { if !$0 { store.pendingReinsert = nil } }),
                            titleVisibility: .visible, presenting: store.pendingReinsert) { item in
            Button("Reinsert on \(item.item.backend.displayName)") { store.reinsert(item, using: model) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(store.current(item).magnet != nil
                 ? "Dove adds the same torrent to \(item.item.backend.displayName) again and deletes this item. Use it for dead, expired or stuck torrents."
                 : "Dove asks nzbdav to queue this job's NZB again (a retry) and removes this entry.")
        }
        .confirmationDialog("Move to \(store.pendingMove?.target.displayName ?? "")?",
                            isPresented: Binding(get: { store.pendingMove != nil }, set: { if !$0 { store.pendingMove = nil } }),
                            titleVisibility: .visible, presenting: store.pendingMove) { move in
            Button("Move (delete from \(move.item.item.backend.displayName))", role: .destructive) {
                store.move(move.item, to: move.target, deleteOriginal: true, using: model)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Dove adds it there first; it deletes this item only after that worked.")
        }
        .alert(store.message ?? "", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") {}
        }
        // A refresh that changes a status lists the files again.
        .task(id: items.map { "\($0.id) \($0.item.status)" }) { await store.loadFiles(items, using: model) }
    }

    private var deleteTitle: String {
        store.pendingDelete.count == 1 ? "Delete this release?" : "Delete \(store.pendingDelete.count) releases?"
    }

    // MARK: Releases

    /// The releases as a hierarchical table: a release's files sit under it (disclosure triangles).
    private var releaseTable: some View {
        let nodes = items.map(releaseNode)
        return Table(nodes, children: \.children, selection: $selection) {
            TableColumn("Name") { node in nameCell(node) }
                .width(min: 240, ideal: 420)
            TableColumn("Service") { node in serviceCell(node) }
                .width(min: 110, ideal: 140)
            TableColumn("Status") { node in statusCell(node) }
                .width(min: 80, ideal: 110)
            TableColumn("Size") { node in sizeCell(node) }
                .width(min: 70, ideal: 90)
            TableColumn("Added") { node in addedCell(node) }
                .width(min: 80, ideal: 100)
            TableColumn("") { node in actionCell(node) }
                .width(min: 90, ideal: 130)
        }
.takesFocusWhenSelected(selection)
        .contextMenu(forSelectionType: ReleaseNode.ID.self) { ids in
            menu(for: chosen(ids, in: nodes))
        } primaryAction: { ids in
            // Double-click: a file plays (or opens in the Finder when it is on this Mac).
            guard case .file(let item, _, let file)? = chosen(ids, in: nodes).first?.kind else { return }
            if item.item.backend.isOnDevice {
                store.reveal(file, of: item, using: model)
            } else if ReleaseStore.canPlay(file.name) {
                store.play(file, of: item, using: model)
            }
        }
    }

    /// A release with its files, or the line that says its files are not listed yet.
    private func releaseNode(_ item: ShelfItem) -> ReleaseNode {
        let release = store.current(item)
        let files = release.files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let children: [ReleaseNode] = files.isEmpty
            ? [ReleaseNode(id: "\(item.id)#note", kind: .note(store.fileNote(item)), children: nil)]
            : files.map { ReleaseNode(id: "\(item.id)#\($0.id)", kind: .file(item, release, $0), children: nil) }
        return ReleaseNode(id: item.id, kind: .release(item, release), children: children)
    }

    /// The selected rows, with their files flattened in, so a menu sees every row the user picked.
    private func chosen(_ ids: Set<ReleaseNode.ID>, in nodes: [ReleaseNode]) -> [ReleaseNode] {
        nodes.flatMap { node in [node] + chosen(ids, in: node.children ?? []) }.filter { ids.contains($0.id) }
    }

    // MARK: Cells

    @ViewBuilder
    private func nameCell(_ node: ReleaseNode) -> some View {
        switch node.kind {
        case .release(let item, _):
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                if item.isRenamed {
                    // The service's own (random) name, so the release can still be found there.
                    Text(item.item.name).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .help(item.name)
        case .file(_, _, let file):
            Text(file.name).lineLimit(1).truncationMode(.middle).help(file.name)
        case .note(let text):
            Text(text).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func serviceCell(_ node: ReleaseNode) -> some View {
        if case .release(let item, _) = node.kind {
            HStack(spacing: 6) {
                BackendBadge(backend: item.item.backend)
                Text(item.item.backend.displayName)
            }
        }
    }

    @ViewBuilder
    private func statusCell(_ node: ReleaseNode) -> some View {
        if case .release(_, let release) = node.kind {
            Text(release.status.label)
        }
    }

    @ViewBuilder
    private func sizeCell(_ node: ReleaseNode) -> some View {
        switch node.kind {
        case .release(_, let release):
            sizeText(release.size)
        case .file(_, _, let file):
            sizeText(file.size)
        case .note:
            EmptyView()
        }
    }

    @ViewBuilder
    private func addedCell(_ node: ReleaseNode) -> some View {
        if case .release(_, let release) = node.kind, let added = release.addedAt {
            Text(added.formatted(date: .abbreviated, time: .omitted))
        }
    }

    /// A file's Play and Download (or Show in Finder for iCloud Drive), as buttons in its row.
    @ViewBuilder
    private func actionCell(_ node: ReleaseNode) -> some View {
        if case .release(let item, let release) = node.kind {
            // The release's actions in plain sight, not only on a right-click.
            Menu("Actions", systemImage: "ellipsis.circle") { releaseMenu(item, release) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("Actions")
        } else if case .file(let item, _, let file) = node.kind {
            HStack(spacing: 6) {
                if item.item.backend.isOnDevice {
                    Button("Show in Finder", systemImage: "folder") { store.reveal(file, of: item, using: model) }
                } else {
                    if ReleaseStore.canPlay(file.name) {
                        Button("Play", systemImage: "play.fill") { store.play(file, of: item, using: model) }
                            .help(model.playback.playLabel)
                    }
                    Button("Download", systemImage: "arrow.down.circle") { store.download(file, of: item, using: model) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func sizeText(_ size: Int64?) -> some View {
        Group {
            if let size, size > 0 {
                Text(size.formatted(.byteCount(style: .file)))
            } else {
                Text("–").foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }

    // MARK: Menus

    /// One release's actions, in the iPhone's ⋯ order (`LibraryItemView`); several rows get the shared actions.
    @ViewBuilder
    private func menu(for nodes: [ReleaseNode]) -> some View {
        if nodes.count == 1, let node = nodes.first {
            switch node.kind {
            case .release(let item, let release):
                releaseMenu(item, release)
            case .file(let item, _, let file):
                fileMenu(file, of: item)
            case .note:
                EmptyView()
            }
        } else {
            let releases = nodes.compactMap { node -> ShelfItem? in
                if case .release(let item, _) = node.kind { return item }
                return nil
            }
            if !releases.isEmpty { actions.menu(releases) }
        }
    }

    @ViewBuilder
    private func releaseMenu(_ item: ShelfItem, _ release: LibraryItem) -> some View {
        if !item.item.backend.isOnDevice {
            Button("Download All", systemImage: "arrow.down.circle") { store.downloadAll(item, using: model) }
                .disabled(release.status != .ready)
            Divider()
        }
        if release.status == .awaitingFileSelection, model.backend(release.backend) is any FileSelecting {
            Button("Choose Files…", systemImage: "checklist") { store.choosingFiles = item }
            Divider()
        }
        // A job nzbdav failed on a compressed archive: the next Usenet service downloads and unpacks it.
        if release.failedOnCompressedArchive, let next = model.compressedArchiveTarget(after: release.backend),
           model.moveTargets(for: release).contains(next) {
            Button("Send to \(next.displayName)", systemImage: "arrow.right.circle") {
                store.move(item, to: next, deleteOriginal: true, using: model)
            }
            Divider()
        }
        if let magnet = release.magnet, let hash = release.infoHash {
            Button("Copy Magnet Link", systemImage: "link") { store.copy(magnet, confirmation: "Magnet copied.") }
            Button("Copy Info Hash", systemImage: "number") { store.copy(hash, confirmation: "Hash copied.") }
            Divider()
        }
        Button("Refresh Status", systemImage: "arrow.triangle.2.circlepath") { store.refreshStatus(item, using: model) }
        if model.canReAdd(release) {
            Button("Reinsert", systemImage: "arrow.clockwise.circle") { store.pendingReinsert = item }
            let targets = model.moveTargets(for: release)
            if !targets.isEmpty {
                Menu("Move To", systemImage: "arrow.right.circle") {
                    ForEach(targets, id: \.self) { target in
                        Menu(target.displayName) {
                            Button("Move") { store.pendingMove = ReleaseStore.PendingMove(item: item, target: target) }
                            Button("Copy") { store.move(item, to: target, deleteOriginal: false, using: model) }
                        }
                    }
                }
            }
        }
        Divider()
        changeTypeMenu(item)
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { store.pendingDelete = [item] }
    }

    /// A file's actions: play, download, copy its name and link, or show it in the Finder.
    @ViewBuilder
    private func fileMenu(_ file: LibraryFile, of item: ShelfItem) -> some View {
        if item.item.backend.isOnDevice {
            Button("Show in Finder", systemImage: "folder") { store.reveal(file, of: item, using: model) }
        } else {
            if ReleaseStore.canPlay(file.name) {
                Button(model.playback.playLabel, systemImage: "play") { store.play(file, of: item, using: model) }
                PlayInMenu { player in store.play(file, of: item, in: player, using: model) }
            }
            Button("Download", systemImage: "arrow.down.circle") { store.download(file, of: item, using: model) }
            if model.iCloudFolder != nil && !item.item.backend.isStorage {
                Button("Save to iCloud Drive", systemImage: "icloud.and.arrow.down") {
                    store.saveToICloud(file, of: item, using: model)
                }
            }
        }
        Divider()
        Button("Copy Name", systemImage: "doc.on.doc") { store.copy(file.name) }
        // Places (iCloud Drive, Calibre) have no service link to share, as on the iPhone.
        if !item.item.backend.isStorage {
            Button("Copy Link", systemImage: "link") { store.copyLink(file, of: item, using: model) }
        }
    }

    /// "Change Type": the kinds and "Automatic", a checkmark on what the user set (as on iPhone).
    private func changeTypeMenu(_ item: ShelfItem) -> some View {
        let manual = model.library.manualKind(of: item)
        return Menu("Change Type", systemImage: "tag") {
            Button {
                store.setKind(nil, for: item, using: model)
            } label: {
                if manual == nil { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            Divider()
            ForEach(ContentKind.allCases, id: \.self) { kind in
                Button {
                    store.setKind(kind, for: item, using: model)
                } label: {
                    Label(kind.displayName, systemImage: manual == kind ? "checkmark" : kind.symbol)
                }
            }
        }
    }

    private var actions: MacLibraryActions {
        .standard(model: model, report: { store.message = $0 }, confirmDelete: { store.pendingDelete = $0 })
    }
}


/// One row of the releases table: a release, one of its files, or the line that says its files are not listed yet.
struct ReleaseNode: Identifiable {
    enum Kind {
        case release(ShelfItem, LibraryItem)
        case file(ShelfItem, LibraryItem, LibraryFile)
        case note(String)
    }

    let id: String
    let kind: Kind
    let children: [ReleaseNode]?
}

