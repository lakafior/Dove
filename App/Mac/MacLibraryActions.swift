import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// What a card, a row or a selection offers, the iPhone Library's context menu: download, Show in Finder, copy
/// magnets, refresh, reinsert, move or copy to another service, change type, delete. Several items run one at a time
/// (`LibraryModel.runBatch`) with one refresh at the end. Built once per screen over the model (`standard`), so the
/// Library, its tables and the item screens share one set.
@MainActor
struct MacLibraryActions {
    let download: @MainActor ([ShelfItem]) -> Void
    let reveal: @MainActor ([ShelfItem]) -> Void
    let delete: @MainActor ([ShelfItem]) -> Void
    let model: AppModel
    let report: @MainActor (String) -> Void

    /// The actions over the model. `report` shows an error or a failure list; `confirmDelete` asks before anything is deleted.
    static func standard(
        model: AppModel,
        report: @escaping @MainActor (String) -> Void,
        confirmDelete: @escaping @MainActor ([ShelfItem]) -> Void
    ) -> MacLibraryActions {
        MacLibraryActions(
            download: { items in
                Task {
                    var failures: [String] = []
                    for item in items {
                        do { try await model.downloadItem(item) } catch { failures.append(error.localizedDescription) }
                    }
                    if !failures.isEmpty { report(failures.joined(separator: "\n")) }
                }
            },
            reveal: { items in
                Task {
                    var files: [URL] = []
                    for item in items {
                        guard let backend = model.backend(item.item.backend) else { continue }
                        do {
                            let full = item.item.files.isEmpty ? try await backend.item(item.item.id) : item.item
                            for file in full.files {
                                if let url = try await backend.downloadRequest(itemID: full.id, fileID: file.id).url { files.append(url) }
                            }
                        } catch {
                            report(error.localizedDescription)
                        }
                    }
                    if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
                }
            },
            delete: confirmDelete,
            model: model,
            report: report
        )
    }

    /// The menu of library cards and rows (titles, books, artists, albums, games, loose files), the same for icons
    /// and tables: Open, Watchlist for a title, Copy Name, then the items' actions (`menu`). `open` is where Open
    /// goes: the Library's `openLibrary`, or a push over an artist's page.
    @ViewBuilder
    func targetMenu(_ targets: [MacRouter.LibraryTarget], open: @escaping @MainActor (MacRouter.LibraryTarget) -> Void) -> some View {
        if let first = targets.first {
            Button("Open", systemImage: "arrow.up.forward.square") { open(first) }
            let albums = targets.flatMap(\.albums)
            if !albums.isEmpty {
                Button("Play", systemImage: "play") { playMusic(albums, shuffled: false) }
                Button("Shuffle", systemImage: "shuffle") { playMusic(albums, shuffled: true) }
            }
            if targets.count == 1, case .title(let title) = first, let media = title.media {
                WatchlistMenuItem(media: media)
            }
            Button("Copy Name", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(targets.map(\.name).joined(separator: "\n"), forType: .string)
            }
            Divider()
            menu(targets.flatMap(\.items))
        }
    }

    private func playMusic(_ albums: [AlbumTitle], shuffled: Bool) {
        Task {
            let title = albums.count == 1 ? albums[0].name : (albums.first?.artist ?? "Music")
            if let notice = await model.playMusic(albums, title: title, cover: albums.first?.album?.cover, shuffled: shuffled) {
                report(notice)
            }
        }
    }

    /// Items on a service are downloaded; items already on this Mac (iCloud Drive) are shown in the Finder.
    @ViewBuilder
    func menu(_ items: [ShelfItem]) -> some View {
        let local = items.filter(\.item.backend.isOnDevice)
        let ready = items.filter { item in
            guard !item.item.backend.isOnDevice else { return false }
            if case .ready = item.item.status { return true }
            return false
        }
        if !ready.isEmpty || local.isEmpty {
            Button(ready.count > 1 ? "Download \(ready.count) Items" : "Download", systemImage: "arrow.down.circle") { download(ready) }
                .disabled(ready.isEmpty)
        }
        if !local.isEmpty {
            Button("Show in Finder", systemImage: "folder") { reveal(local) }
        }
        let magnets = items.compactMap(\.item.magnet)
        if !magnets.isEmpty {
            Button(magnets.count > 1 ? "Copy \(magnets.count) Magnet Links" : "Copy Magnet Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(magnets.joined(separator: "\n"), forType: .string)
            }
        }
        Divider()
        Button("Refresh Status", systemImage: "arrow.triangle.2.circlepath") {
            Task { await model.library.refresh(using: model, afterChange: true) }
        }
        let reAddable = items.filter { model.canReAdd($0.item) }
        if !reAddable.isEmpty {
            Button(reAddable.count > 1 ? "Reinsert \(reAddable.count) Items" : "Reinsert", systemImage: "arrow.clockwise.circle") {
                Task { await model.library.reinsert(reAddable, using: model) }
            }
            let targets = Self.moveTargets(for: reAddable, model: model)
            if !targets.isEmpty {
                Menu("Move To", systemImage: "arrow.right.circle") {
                    ForEach(targets, id: \.self) { target in
                        Menu(target.displayName) {
                            Button("Move (Delete Originals)") {
                                Task { await model.library.move(reAddable, to: target, deleteOriginal: true, using: model) }
                            }
                            Button("Copy") {
                                Task { await model.library.move(reAddable, to: target, deleteOriginal: false, using: model) }
                            }
                        }
                    }
                }
            }
        }
        kindMenu(items)
        Divider()
        Button(items.count > 1 ? "Delete \(items.count) Items…" : "Delete…", systemImage: "trash", role: .destructive) { delete(items) }
    }

    /// Services every one of the items can go to.
    private static func moveTargets(for items: [ShelfItem], model: AppModel) -> [BackendID] {
        guard let first = items.first else { return [] }
        let common = items.dropFirst().reduce(Set(model.moveTargets(for: first.item))) { $0.intersection(model.moveTargets(for: $1.item)) }
        return model.moveTargets(for: first.item).filter(common.contains)
    }

    /// "Change Type" for the items; a checkmark on the kind the user set for all of them.
    private func kindMenu(_ items: [ShelfItem]) -> some View {
        let manual = Set(items.map { model.library.manualKind(of: $0) })
        let current = manual.count == 1 ? manual.first! : nil
        return Menu("Change Type", systemImage: "tag") {
            Button {
                Task { await model.library.setKind(nil, for: items, using: model) }
            } label: {
                if manual == [nil] { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            Divider()
            ForEach(ContentKind.allCases, id: \.self) { kind in
                Button {
                    Task { await model.library.setKind(kind, for: items, using: model) }
                } label: {
                    Label(kind.displayName, systemImage: current == kind ? "checkmark" : kind.symbol)
                }
            }
        }
    }
}

extension MacRouter.LibraryTarget {
    /// Its row in the Library's list and its card in the icons (`TitleRow.id`): one selection for both.
    var rowID: String {
        switch self {
        case .title(let title): "title:\(title.id)"
        case .book(let book): "book:\(book.id)"
        case .album(let album): "album:\(album.id)"
        case .artist(let artist): "artist:\(artist.id)"
        case .game(let game): "game:\(game.id)"
        case .item(let item): "item:\(item.id)"
        }
    }

    /// The name its card or row shows.
    var name: String {
        switch self {
        case .title(let title): title.name
        case .book(let book): book.name
        case .album(let album): album.name
        case .artist(let artist): artist.name
        case .game(let game): game.name
        case .item(let item): item.name
        }
    }

    /// The albums it plays in Dove's player (an album, an artist's); none for other kinds.
    var albums: [AlbumTitle] {
        switch self {
        case .album(let album): [album]
        case .artist(let artist): artist.albums
        default: []
        }
    }

    /// Every release behind it (an artist's: its albums').
    var items: [ShelfItem] {
        switch self {
        case .title(let title): title.items
        case .book(let book): book.items
        case .album(let album): album.items
        case .artist(let artist): artist.albums.flatMap(\.items)
        case .game(let game): game.items
        case .item(let item): [item]
        }
    }
}

/// The confirmation and the alert behind `MacLibraryActions` on a page: Delete asks first, failures show.
struct LibraryActionDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pendingDelete: [ShelfItem]
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(question, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
                Button("Delete", role: .destructive) {
                    let items = pendingDelete
                    Task { await model.library.delete(items, using: model) }
                }
            } message: {
                Text("They are deleted on the services that hold them.")
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") {}
            }
    }

    private var question: String {
        pendingDelete.count == 1 ? "Delete \(pendingDelete[0].name)?" : "Delete \(pendingDelete.count) items?"
    }
}

/// A page's own Download (Show in Finder for iCloud Drive) and its one ⋯, next to Play, as in Music and TV: the page's
/// own items first (`page`: Wrong Title?, Find Other Releases…), then every action of its releases. The toolbar keeps
/// only the view switch and the Watchlist bookmark.
struct MacItemsButtons<Page: View>: View {
    let items: [ShelfItem]
    let actions: MacLibraryActions
    @ViewBuilder var page: Page

    init(items: [ShelfItem], actions: MacLibraryActions, @ViewBuilder page: () -> Page = { EmptyView() }) {
        self.items = items
        self.actions = actions
        self.page = page()
    }

    var body: some View {
        let local = items.filter(\.item.backend.isOnDevice)
        let ready = items.filter { !$0.item.backend.isOnDevice && $0.item.status == .ready }
        Group {
            if !local.isEmpty && ready.isEmpty {
                Button("Show in Finder", systemImage: "folder") { actions.reveal(local) }
            } else {
                Button("Download", systemImage: "arrow.down.circle") { actions.download(ready) }
                    .disabled(ready.isEmpty)
                    .help(ready.isEmpty ? "Nothing is ready on a service yet" : "Download every file to this Mac")
            }
            Menu {
                if Page.self != EmptyView.self {
                    page
                    Divider()
                }
                actions.menu(items)
            } label: {
                // Text, not a bare symbol: a symbol-only label makes a shorter button than its neighbours.
                Text("•••").font(.caption2.weight(.heavy)).frame(minWidth: 18)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
            .accessibilityLabel("More actions")
        }
        .buttonStyle(.bordered)
    }
}
