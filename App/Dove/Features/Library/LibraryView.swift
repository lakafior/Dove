import DoveKit
import SwiftUI

/// Everything in every debrid, either as titles with posters (matched through the search addon)
/// or as the raw list of torrents and downloads. Music, books, software and the rest are listed by name
/// under the posters. Filters: services, category, status, text.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("libraryMode") private var mode: Mode = .titles
    @State private var filter = LibraryFilter()
    /// Files view: several items picked for one delete.
    @State private var isSelecting = false
    @State private var selection = Set<ShelfItem.ID>()
    @State private var confirmDelete = false
    @State private var deleting: (done: Int, total: Int)?

    enum Mode: String, CaseIterable {
        case titles, files
        var title: String { self == .titles ? "Titles" : "Files" }
    }

    private var library: LibraryModel { model.library }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .titles: titlesView
                case .files: filesView
                }
            }
            .overlay { emptyState }
            .navigationTitle("Library")
            .searchable(text: $filter.query, prompt: "Filter")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .primaryAction) { filterMenu }
                ToolbarItem(placement: .secondaryAction) {
                    // Same as pulling the list down: every service's list, statuses included, one call each.
                    Button(library.isLoading ? "Refreshing…" : "Refresh all statuses", systemImage: "arrow.clockwise") {
                        Task { await library.refresh(using: model) }
                    }
                    .disabled(library.isLoading)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button(library.isRematching ? "Re-matching…" : "Re-match all titles", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await library.rematchAll(using: model) }
                    }
                    .disabled(library.isRematching || !model.addonSet.canSearch)
                }
                ToolbarItem(placement: .secondaryAction) {
                    @Bindable var model = model
                    Toggle("Show adult content", systemImage: "eye", isOn: $model.showAdult)
                }
                if mode == .files {
                    ToolbarItem(placement: .topBarLeading) { selectButton }
                }
            }
            .onChange(of: mode) { endSelecting() }
            .navigationDestination(for: TitleRoute.self) { LibraryTitleView(titleID: $0.id) }
            .navigationDestination(for: ShelfItem.self) { LibraryItemView(item: $0.item) }
            .refreshable { await library.refresh(using: model) }
            .task {
                if !library.hasLoaded { await library.refresh(using: model) }
            }
        }
    }

    // MARK: - Titles

    private var titlesView: some View {
        let titles = filter.apply(to: library.titles)
        let others = filter.apply(to: library.others)
        return ScrollView {
            failuresBanner.padding(.horizontal)
            titleGrid("Movies", titles.filter { $0.type == .movie })
            titleGrid("Series", titles.filter { $0.type == .series })
            if !others.isEmpty {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Other files").font(.title3.bold())
                        Text("\(others.count)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)
                    ForEach(others) { item in
                        NavigationLink(value: item) {
                            ShelfItemRow(item: item, showsBackend: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            kindMenu([item])
                            deleteButton(item)
                        }
                        Divider()
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }

    /// One kind of title under its own heading; nothing when there are none (e.g. filtered to the other kind).
    @ViewBuilder
    private func titleGrid(_ heading: String, _ titles: [LibraryTitle]) -> some View {
        if !titles.isEmpty {
            LazyVStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(heading).font(.title3.bold())
                    Text("\(titles.count)").font(.subheadline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                    ForEach(titles) { title in
                        NavigationLink(value: TitleRoute(id: title.id)) {
                            TitleCard(title: title)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { kindMenu(title.items) }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    // MARK: - Files

    private var filesView: some View {
        let items = filter.apply(to: library.items)
        return List(selection: $selection) {
            failuresBanner
            ForEach(items) { item in
                NavigationLink(value: item) { ShelfItemRow(item: item, showsBackend: true) }
                    .swipeActions { deleteButton(item) }
                    .contextMenu {
                        kindMenu([item])
                        deleteButton(item)
                    }
            }
        }
        .environment(\.editMode, .constant(isSelecting ? .active : .inactive))
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar(visible: items) }
        }
        .confirmationDialog(
            "Delete \(selection.count) items?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete from their services", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each item is removed from its debrid or nzbdav, with its files. This cannot be undone.")
        }
    }

    private var selectButton: some View {
        Button(isSelecting ? "Done" : "Select") {
            if isSelecting { endSelecting() } else { isSelecting = true }
        }
        .disabled(deleting != nil)
    }

    /// Select all of what the filters show (e.g. one service), or delete the picked ones.
    private func selectionBar(visible items: [ShelfItem]) -> some View {
        HStack {
            Button(selection.count == items.count && !items.isEmpty ? "Select none" : "Select all") {
                selection = selection.count == items.count ? [] : Set(items.map(\.id))
            }
            Spacer()
            if deleting == nil {
                kindMenu(library.items.filter { selection.contains($0.id) })
                    .disabled(selection.isEmpty)
            }
            if let deleting {
                ProgressView()
                Text("Deleting \(deleting.done) of \(deleting.total)…").font(.footnote)
            } else {
                Button("Delete \(selection.count)", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selection.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .disabled(deleting != nil)
    }

    /// One by one, so a failure (shown with the other failures) does not stop the rest.
    private func deleteSelection() {
        let picked = library.items.filter { selection.contains($0.id) }
        deleting = (0, picked.count)
        Task {
            for item in picked {
                await library.delete(item, using: model)
                deleting?.done += 1
            }
            deleting = nil
            endSelecting()
        }
    }

    private func endSelecting() {
        isSelecting = false
        selection = []
    }

    // MARK: - Pieces

    @ViewBuilder
    private var failuresBanner: some View {
        if !library.failures.isEmpty {
            Label(library.failures.joined(separator: "\n"), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.backends.isEmpty {
            ContentUnavailableView("Nothing configured", systemImage: "key", description: Text("Add an API key in Settings."))
        } else if library.isLoading && library.items.isEmpty {
            ProgressView()
        } else if library.hasLoaded && library.items.isEmpty {
            ContentUnavailableView("Your library is empty", systemImage: "tray")
        } else if library.hasLoaded && filter.apply(to: library.items).isEmpty {
            ContentUnavailableView.search(text: filter.query)
        }
    }

    private var filterMenu: some View {
        Menu("Filters", systemImage: filter.isActive
             ? "line.3.horizontal.decrease.circle.fill"
             : "line.3.horizontal.decrease.circle") {
            Section("Services") {
                ForEach(model.backends.map(\.id), id: \.self) { backend in
                    Toggle(backend.displayName, isOn: Binding(
                        get: { filter.backends.contains(backend) },
                        set: { on in
                            if on { filter.backends.insert(backend) } else { filter.backends.remove(backend) }
                        }
                    ))
                }
            }
            Picker("Type", selection: $filter.category) {
                Text("Everything").tag(LibraryFilter.Category?.none)
                ForEach(LibraryFilter.Category.allCases.filter { $0 != .adult || model.showAdult }, id: \.self) {
                    Text($0.title).tag(LibraryFilter.Category?.some($0))
                }
            }
            Picker("Status", selection: $filter.status) {
                Text("Any status").tag(LibraryFilter.Status?.none)
                ForEach(LibraryFilter.Status.allCases, id: \.self) { Text($0.title).tag(LibraryFilter.Status?.some($0)) }
            }
            if filter.isActive {
                Button("Clear filters", role: .destructive) {
                    let query = filter.query
                    filter = LibraryFilter()
                    filter.query = query
                }
            }
        }
    }

    /// "Change type": the kind for these items (a whole title, one row, or the selection). A checkmark marks
    /// the kind the user already set; "Automatic" goes back to what the files and the name say.
    private func kindMenu(_ items: [ShelfItem]) -> some View {
        let manual = Set(items.map { library.manualKind(of: $0) })
        let current = manual.count == 1 ? manual.first! : nil
        return Menu("Change type", systemImage: "tag") {
            Button {
                Task { await library.setKind(nil, for: items, using: model) }
            } label: {
                if manual == [nil] { Label("Automatic", systemImage: "checkmark") } else { Text("Automatic") }
            }
            Divider()
            ForEach(ContentKind.allCases, id: \.self) { kind in
                Button {
                    Task { await library.setKind(kind, for: items, using: model) }
                } label: {
                    Label(kind.displayName, systemImage: current == kind ? "checkmark" : kind.symbol)
                }
            }
        }
    }

    private func deleteButton(_ item: ShelfItem) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            Task { await library.delete(item, using: model) }
        }
    }
}

struct TitleRoute: Hashable {
    let id: String
}

/// Poster tile: artwork (or the title on a plain card), name, year, services, and a status mark.
private struct TitleCard: View {
    let title: LibraryTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                AsyncImage(url: title.media?.poster) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text(title.name)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(6)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                statusMark.padding(5)
            }
            .overlay(alignment: .topLeading) {
                if let coverage = title.coverage {
                    Text(coverage)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(5)
                }
            }
            Text(title.name).font(.caption.weight(.medium)).lineLimit(1)
            HStack(spacing: 3) {
                if let year = title.year { Text(year).font(.caption2).foregroundStyle(.secondary) }
                Spacer(minLength: 2)
                ForEach(title.backends, id: \.self) { BackendBadge(backend: $0) }
            }
        }
    }

    @ViewBuilder
    private var statusMark: some View {
        switch title.status {
        case .ready:
            if title.items.count > 1 {
                Text("\(title.items.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        case .active:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.white, .blue)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red)
        }
    }
}

/// One torrent or download: name, service, what it holds (episode, season, music…), status, size.
struct ShelfItemRow: View {
    let item: ShelfItem
    var showsBackend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.item.name).font(.subheadline).lineLimit(2)
            HStack(spacing: 8) {
                if showsBackend { BackendBadge(backend: item.item.backend) }
                if item.kind != .video {
                    Label(item.kind.displayName, systemImage: item.kind.symbol)
                } else if let scope = item.guess.scope {
                    Text(scope.label).fontWeight(.medium)
                }
                Text(item.item.status.label)
                if let size = item.item.size {
                    Text(size.formatted(.byteCount(style: .file)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Files of one item, each playable in Infuse or copyable as a link.
struct LibraryItemView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem
    @State private var detail: LibraryItem?
    @State private var message: String?
    @State private var isChoosingFiles = false
    @State private var confirmReinsert = false
    @State private var pendingMove: BackendID?
    @State private var isWorking = false

    private var current: LibraryItem { detail ?? item }

    /// Other debrids that take torrents, in priority order: where "Move to" can send this one.
    private var moveTargets: [BackendID] {
        model.backends(usenet: false).map(\.id).filter { $0 != item.backend }
    }

    /// In name order, so episodes read E01, E02… (services list them in their own order).
    private var files: [LibraryFile] {
        (detail ?? item).files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Set when the service waits for the user to pick files (Real-Debrid).
    private var fileSelector: (any FileSelecting)? {
        guard (detail ?? item).status == .awaitingFileSelection else { return nil }
        return model.backend(item.backend) as? any FileSelecting
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Service") { BackendBadge(backend: item.backend) }
                LabeledContent("Status", value: (detail ?? item).status.label)
                if let size = item.size {
                    LabeledContent("Size", value: size.formatted(.byteCount(style: .file)))
                }
            }
            if let message {
                Text(message).font(.footnote)
            }
            if fileSelector != nil {
                Section {
                    Button("Choose files", systemImage: "checklist") { isChoosingFiles = true }
                } footer: {
                    Text("\(item.backend.displayName) waits for you to choose which files to download.")
                }
            }
            Section("Files") {
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(file.name).font(.subheadline)
                        HStack(spacing: 10) {
                            if let size = file.size {
                                Text(size.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { copyLink(file) } label: { Image(systemName: "link") }
                                .accessibilityLabel("Copy link")
                            downloadButton(file)
                            // Infuse plays video; other files are for the link or the phone.
                            if FileKind.isVideo(file.name) {
                                Button { play(file) } label: { Image(systemName: "play.fill") }
                                    .accessibilityLabel("Play in Infuse")
                            }
                        }
                        // Bordered buttons keep their own tap areas inside a list row.
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .contextMenu {
                        if FileKind.isVideo(file.name) {
                            Button("Play in Infuse", systemImage: "play") { play(file) }
                        }
                        Button("Copy link", systemImage: "link") { copyLink(file) }
                        Button("Download to phone", systemImage: "arrow.down.circle") { download(file) }
                    }
                }
            }
        }
        .overlay {
            if detail == nil && files.isEmpty && message == nil { ProgressView() }
        }
        .sheet(isPresented: $isChoosingFiles) {
            // Not `fileSelector`: the status changes on success, before the sheet is dismissed.
            if let backend = model.backend(item.backend) as? any FileSelecting {
                FileSelectionView(backend: backend, itemID: item.id) {
                    await loadDetail()
                    await model.library.refresh(using: model)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { actionsMenu }
        }
        .confirmationDialog("Add this torrent again?", isPresented: $confirmReinsert, titleVisibility: .visible) {
            Button("Reinsert on \(item.backend.displayName)") { reinsert() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Dove adds the same torrent to \(item.backend.displayName) again and deletes this item. Use it for dead, expired or stuck torrents.")
        }
        .confirmationDialog(
            "Move to \(pendingMove?.displayName ?? "")?",
            isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } }),
            titleVisibility: .visible,
            presenting: pendingMove
        ) { target in
            Button("Move (delete from \(item.backend.displayName))") { move(to: target, deleteOriginal: true) }
            Button("Copy (keep it here too)") { move(to: target, deleteOriginal: false) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Dove adds the torrent there first; it deletes this item only after that worked.")
        }
        .disabled(isWorking)
        .refreshable { await loadDetail() }
        .task { await loadDetail() }
    }

    /// DMM-style actions for torrents (by info hash), and a status refresh for everything.
    private var actionsMenu: some View {
        Menu("Actions", systemImage: "ellipsis.circle") {
            if let magnet = current.magnet, let hash = current.infoHash {
                Section {
                    Button("Copy magnet", systemImage: "link") { copy(magnet, "Magnet copied.") }
                    Button("Copy hash", systemImage: "number") { copy(hash, "Hash copied.") }
                }
                Section {
                    Button("Reinsert", systemImage: "arrow.clockwise.circle") { confirmReinsert = true }
                    if !moveTargets.isEmpty {
                        Menu("Move to", systemImage: "arrow.right.circle") {
                            ForEach(moveTargets, id: \.self) { target in
                                Button(target.displayName) { pendingMove = target }
                            }
                        }
                    }
                }
            }
            Button("Refresh status", systemImage: "arrow.triangle.2.circlepath") {
                Task {
                    message = nil
                    await loadDetail()
                    if message == nil { message = "Status: \(current.status.label)." }
                }
            }
        }
    }

    private func copy(_ text: String, _ confirmation: String) {
        UIPasteboard.general.string = text
        message = confirmation
    }

    private func reinsert() {
        guard let backend = model.backend(item.backend) else { return }
        run("Reinserting…") {
            _ = try await LibraryActions.reinsert(current, on: backend)
            return true
        }
    }

    private func move(to target: BackendID, deleteOriginal: Bool) {
        guard let source = model.backend(item.backend), let destination = model.backend(target) else { return }
        run("Adding to \(target.displayName)…") {
            _ = try await LibraryActions.move(current, from: source, to: destination, deleteOriginal: deleteOriginal)
            if !deleteOriginal { message = "Added to \(target.displayName)." }
            return deleteOriginal
        }
    }

    /// Runs an action, refreshes the library, and leaves the screen when the item is gone.
    private func run(_ progress: String, _ action: @escaping () async throws -> Bool) {
        isWorking = true
        message = progress
        Task {
            defer { isWorking = false }
            do {
                let removed = try await action()
                await model.library.refresh(using: model)
                if removed { dismiss() } else if message == progress { message = nil }
            } catch {
                message = error.localizedDescription
                await model.library.refresh(using: model)
            }
        }
    }

    /// Some backends (Real-Debrid, Offcloud) only return files from a per-item call.
    private func loadDetail() async {
        guard let backend = model.backend(item.backend) else { return }
        do {
            let loaded = try await backend.item(item.id)
            detail = loaded
            model.library.learnKind(from: loaded)
        } catch {
            message = error.localizedDescription
        }
    }

    private func link(for file: LibraryFile) async -> URL? {
        guard let backend = model.backend(item.backend) else { return nil }
        do {
            // nzbdav's link carries the WebDAV login; players and copied links cannot send headers.
            return try await backend.playbackURL(itemID: item.id, fileID: file.id)
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    private func play(_ file: LibraryFile) {
        Task {
            if let url = await link(for: file), let infuse = Infuse.playURL(for: url) { openURL(infuse) }
        }
    }

    /// Shows where the file stands on this device: download, progress, or done.
    @ViewBuilder
    private func downloadButton(_ file: LibraryFile) -> some View {
        let record = model.downloads.records.first {
            $0.isSameFile(backend: item.backend, itemID: item.id, fileID: file.id)
        }
        switch record?.state {
        case .downloading:
            Button {} label: {
                ProgressRing(progress: record?.progress ?? 0)
            }
            .disabled(true)
            .accessibilityLabel("Downloading")
        case .finished:
            Button {} label: { Image(systemName: "checkmark") }
                .disabled(true)
                .accessibilityLabel("Downloaded")
        default:
            Button { download(file) } label: { Image(systemName: "arrow.down") }
                .accessibilityLabel("Download to phone")
        }
    }

    private func download(_ file: LibraryFile) {
        Task {
            do {
                try await model.download(file, of: detail ?? item)
                message = "Downloading \(file.name). Progress is in the Downloads tab."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func copyLink(_ file: LibraryFile) {
        Task {
            if let url = await link(for: file) {
                UIPasteboard.general.url = url
                message = "Link copied."
            }
        }
    }
}

extension LibraryItem.Status {
    var label: String {
        switch self {
        case .queued: "Queued"
        case .awaitingFileSelection: "Choose files"
        case .downloading(let progress): "Downloading \(Int(progress * 100))%"
        case .ready: "Ready"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

/// Small determinate ring; sized like an SF Symbol in a small button.
private struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 13, height: 13)
    }
}
