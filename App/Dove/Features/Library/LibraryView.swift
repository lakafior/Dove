import DoveKit
import SwiftUI

/// Everything in every debrid, either as titles with posters (matched through the search addon)
/// or as the raw list of torrents and downloads. Filters: services, type, status, text.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("libraryMode") private var mode: Mode = .titles
    @State private var filter = LibraryFilter()

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
            }
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
        return ScrollView {
            failuresBanner.padding(.horizontal)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)], spacing: 16) {
                ForEach(titles) { title in
                    NavigationLink(value: TitleRoute(id: title.id)) {
                        TitleCard(title: title)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    // MARK: - Files

    private var filesView: some View {
        let items = filter.apply(to: library.items)
        return List {
            failuresBanner
            ForEach(items) { item in
                NavigationLink(value: item) { ShelfItemRow(item: item, showsBackend: true) }
                    .swipeActions { deleteButton(item) }
            }
        }
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
            Picker("Type", selection: $filter.type) {
                Text("Movies and series").tag(MediaType?.none)
                Text("Movies").tag(MediaType?.some(.movie))
                Text("Series").tag(MediaType?.some(.series))
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

    private func deleteButton(_ item: ShelfItem) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) {
            Task { try? await library.delete(item, using: model) }
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

/// One torrent or download: name, service, status, size.
struct ShelfItemRow: View {
    let item: ShelfItem
    var showsBackend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.item.name).font(.subheadline).lineLimit(2)
            HStack(spacing: 8) {
                if showsBackend { BackendBadge(backend: item.item.backend) }
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
    let item: LibraryItem
    @State private var detail: LibraryItem?
    @State private var message: String?

    private var files: [LibraryFile] { (detail ?? item).files }

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
            Section("Files") {
                ForEach(files) { file in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(file.name).font(.subheadline)
                            if let size = file.size {
                                Text(size.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            play(file)
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Play in Infuse")
                    }
                    .contextMenu {
                        Button("Play in Infuse", systemImage: "play") { play(file) }
                        Button("Copy link", systemImage: "link") { copyLink(file) }
                        // TODO(stage-1): "Download to phone" via the background download manager.
                    }
                }
            }
        }
        .overlay {
            if detail == nil && files.isEmpty && message == nil { ProgressView() }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadDetail() }
        .task { await loadDetail() }
    }

    /// Some backends (Real-Debrid, Offcloud) only return files from a per-item call.
    private func loadDetail() async {
        guard let backend = model.backend(item.backend) else { return }
        do {
            detail = try await backend.item(item.id)
        } catch {
            message = error.localizedDescription
        }
    }

    private func link(for file: LibraryFile) async -> URL? {
        guard let backend = model.backend(item.backend) else { return nil }
        do {
            return try await backend.downloadRequest(itemID: item.id, fileID: file.id).url
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
        case .downloading(let progress): "Downloading \(Int(progress * 100))%"
        case .ready: "Ready"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}
