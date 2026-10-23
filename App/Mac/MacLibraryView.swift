import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// The Library for one sidebar entry (all, or one kind). Its titles as icons (cover grids) or as a table, one setting
/// for the whole Library (`LibraryViewMode`). The root of the Library's stack (`MacLibraryStack`): a title opens its
/// screen over it.
struct MacLibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    let category: LibraryFilter.Category?

    @AppStorage(LibraryViewMode.storageKey) private var mode: LibraryViewMode = .icons
    @State private var query = ""
    /// The iPhone's Filters menu: services and status (the kind is the sidebar's).
    @State private var backends = Set<BackendID>()
    @State private var status: LibraryFilter.Status?
    /// What is selected, in the icons and the list alike (`TitleRow.id`); the toolbar's Share and Action menu act on it.
    @State private var selection = Set<String>()
    @State private var pendingDelete: [ShelfItem] = []
    @State private var message: String?

    private var library: LibraryModel { model.library }

    private var filter: LibraryFilter {
        var filter = LibraryFilter()
        filter.category = category
        filter.query = query
        filter.backends = backends
        filter.status = status
        return filter
    }

    var body: some View {
        Group {
            if library.items.isEmpty {
                emptyState
            } else if mode == .icons {
                MacLibraryTitles(filter: filter, actions: actions, selection: $selection)
            } else {
                MacLibraryTitleTable(filter: filter, actions: actions, selection: $selection)
            }
        }
        .navigationTitle(category?.title ?? "Library")
        .onChange(of: category) { selection = [] }
        .navigationSubtitle(statusLine)
        .searchable(text: $query, placement: .toolbar, prompt: "Filter")
        .toolbar {
            // Where the Finder has it: first in the trailing group, before the actions and search.
            ToolbarItem(placement: .primaryAction) {
                ViewModePicker(mode: $mode)
            }
            ToolbarItem(placement: .primaryAction) { filterMenu }
            ToolbarItem(placement: .primaryAction) { shareButton }
            ToolbarItem(placement: .primaryAction) { moreMenu }
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await library.refresh(using: model) }
                }
                .keyboardShortcut("r")
                .disabled(library.isLoading)
            }
        }
        .safeAreaInset(edge: .top) {
            if !library.failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(library.failures, id: \.self) { Label($0, systemImage: "exclamationmark.triangle") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.orange.opacity(0.12))
            }
        }
        .confirmationDialog(deleteQuestion, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button("Delete", role: .destructive) {
                let items = pendingDelete
                Task { await library.delete(items, using: model) }
            }
        } message: {
            Text("They are deleted on the services that hold them.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }

    // MARK: Menus

    private var filterMenu: some View {
        let isActive = !backends.isEmpty || status != nil
        return Menu("Filters", systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
            Section("Services") {
                ForEach(model.backends.map(\.id), id: \.self) { backend in
                    Toggle(backend.displayName, isOn: Binding(
                        get: { backends.contains(backend) },
                        set: { on in
                            if on { backends.insert(backend) } else { backends.remove(backend) }
                        }
                    ))
                }
            }
            Picker("Status", selection: $status) {
                Text("Any Status").tag(LibraryFilter.Status?.none)
                ForEach(LibraryFilter.Status.allCases, id: \.self) { Text($0.title).tag(LibraryFilter.Status?.some($0)) }
            }
            if isActive {
                Divider()
                Button("Clear Filters") {
                    backends = []
                    status = nil
                }
            }
        }
        .help("Filters")
    }

    /// The selected titles, in the list's order.
    private var selectedTargets: [MacRouter.LibraryTarget] {
        guard !selection.isEmpty else { return [] }
        return TitleRow.rows(filter: filter, library: library).filter { selection.contains($0.id) }.map(\.target)
    }

    /// Share, as the Finder's: the selection's magnet links (what another app or person can add), else their names.
    @ViewBuilder
    private var shareButton: some View {
        let targets = selectedTargets
        let magnets = targets.flatMap(\.items).compactMap(\.item.magnet)
        let lines = magnets.isEmpty ? targets.map(\.name) : magnets
        ShareLink(items: lines) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .disabled(lines.isEmpty)
        .help(magnets.isEmpty ? "Share the selected names" : "Share the selected magnet links")
    }

    /// The Finder's Action menu: what the context menu offers for the selection, then the page's own (the iPhone
    /// Library's ⋯): Shuffle All for music, Re-match All Titles, Show Adult Content.
    private var moreMenu: some View {
        @Bindable var model = model
        let targets = selectedTargets
        return Menu("Action", systemImage: "ellipsis.circle") {
            if !targets.isEmpty {
                actions.targetMenu(targets) { router.openLibrary($0) }
                Divider()
            }
            if category == .music {
                Button("Shuffle All", systemImage: "shuffle") {
                    Task {
                        let albums = LibraryShelf.albums(filter.apply(to: library.items), matches: library.albumMatches)
                        if let notice = await model.playMusic(albums, title: "All music", shuffled: true) { message = notice }
                    }
                }
                Divider()
            }
            Button(library.isRematching ? "Re-matching…" : "Re-match All Titles", systemImage: "arrow.triangle.2.circlepath") {
                Task { await library.rematchAll(using: model) }
            }
            .disabled(library.isRematching)
            Toggle("Show Adult Content", systemImage: "eye", isOn: $model.showAdult)
        }
    }

    private var actions: MacLibraryActions {
        .standard(model: model, report: { message = $0 }, confirmDelete: { pendingDelete = $0 })
    }

    /// "Updated 2 minutes ago · 46 items, 1.1 TB", like the iPhone's status line.
    private var statusLine: String {
        if library.isLoading { return "Updating…" }
        let usage = LibraryUsage(filter.apply(to: library.items))
        let count = usage.items == 1 ? "1 item" : "\(usage.items) items"
        let size = usage.bytes > 0 ? "\(count), \(usage.bytes.formatted(.byteCount(style: .file)))" : count
        guard let updatedAt = library.updatedAt else { return size }
        return "Updated \(updatedAt.formatted(.relative(presentation: .named))) · \(size)"
    }

    private var deleteQuestion: String {
        pendingDelete.count == 1 ? "Delete \(pendingDelete[0].name)?" : "Delete \(pendingDelete.count) items?"
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.isLoading || !library.hasLoaded {
            ProgressView("Loading the library…")
        } else {
            ContentUnavailableView("Nothing here yet", systemImage: "books.vertical",
                                   description: Text("What you add to your services shows up here."))
        }
    }
}
