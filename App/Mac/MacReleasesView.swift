import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// A book, audiobook, album or game picked in search: what it is, then its releases from Dove's indexers (this one's
/// first, the rest behind "Show other results") and from the plugins. The search, the split and the add are
/// `ReleaseList` and `PluginSearch` in `DoveAppCore`, the iPhone's own.
struct MacReleasesView: View {
    @Environment(AppModel.self) private var model
    let target: ReleaseTarget

    @State private var releases: ReleaseList
    @State private var plugins = PluginSearch()
    @State private var tab = Tab.indexers

    enum Tab { case indexers, plugins }

    init(target: ReleaseTarget) {
        self.target = target
        let list: ReleaseList = switch target {
        case .book(let book, let format): ReleaseList(book: book, format: format)
        case .album(let album): ReleaseList(album: album)
        case .game(let game): ReleaseList(game: game)
        }
        _releases = State(initialValue: list)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if tab == .indexers {
                MacReleasesTable(list: releases)
            } else {
                MacPluginResults(search: plugins)
            }
        }
        .navigationTitle(target.title)
        .toolbar {
            if !plugins.isEmpty || plugins.isSearching {
                ToolbarItem(placement: .principal) {
                    Picker("Results", selection: $tab) {
                        Text("Indexers").tag(Tab.indexers)
                        Text("Plugins (\(plugins.resultCount))").tag(Tab.plugins)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .task { search() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CachedImage(url: target.cover) { Rectangle().fill(.quaternary) }
                .frame(width: 138 * target.ratio, height: 138)
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(target.title).font(.title.bold())
                if let subtitle = target.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                if let description = target.description {
                    Text(description).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    /// The iPhone's queries: `t=book` / `t=music` where the indexers know them, the game's title without an article.
    private func search() {
        switch target {
        case .book(let book, let format):
            let category: SearchCategory = format == .audiobook ? .audiobooks : .books
            if let newznab = category.newznabCategory {
                releases.search(.book(title: book.searchTitle, author: book.authors.first, category: newznab), in: category, model: model)
            }
            let words = [book.authors.first, book.searchTitle].compactMap { $0 }.joined(separator: " ")
            plugins.search(words, category: category, book: book, calls: model.plugins.calls(.search, category: category))
        case .album(let album):
            releases.search(.album(title: album.searchTitle, artist: album.artists.first), in: .music, model: model)
            let words = [album.artist, album.searchTitle].compactMap { $0 }.joined(separator: " ")
            plugins.search(words, category: .music, album: album, calls: model.plugins.calls(.search, category: .music))
        case .game(let game):
            releases.search(.text(game.indexerQuery, category: .games), in: .games, model: model)
            plugins.search(game.indexerQuery, category: .games, calls: model.plugins.calls(.search, category: .games))
        }
    }
}

/// What a releases page is for.
enum ReleaseTarget: Hashable {
    case book(BookSummary, BookFormat)
    case album(AlbumSummary)
    case game(GameSummary)

    var title: String {
        switch self {
        case .book(let book, _): book.title
        case .album(let album): album.title
        case .game(let game): game.title
        }
    }

    var subtitle: String? {
        let parts: [String?] = switch self {
        case .book(let book, let format): [book.authors.first, book.year.map(String.init), format == .audiobook ? "Audiobook" : nil]
        case .album(let album): [album.artist, album.year.map(String.init), album.type]
        case .game(let game): [game.year.map(String.init)] + game.platforms.prefix(4).map(\.displayName)
        }
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    var description: String? {
        switch self {
        case .book(let book, _): book.description
        case .album: nil
        case .game(let game): game.summary
        }
    }

    var cover: URL? {
        switch self {
        case .book(let book, _): book.cover
        case .album(let album): album.cover
        case .game(let game): game.cover
        }
    }

    /// Width ÷ height of the cover.
    var ratio: CGFloat {
        switch self {
        case .book(_, let format): format.coverRatio
        case .album: 1
        case .game: 3 / 4
        }
    }
}

/// Releases from the indexers as a table: this item's first (others behind a button), sortable, Return or a
/// double-click adds (Automatic: cached services first), the context menu copies the name.
struct MacReleasesTable: View {
    @Environment(AppModel.self) private var model
    let list: ReleaseList

    @State private var selection = Set<StreamGroup.ID>()
    @State private var order: [KeyPathComparator<SourceRowValues>] = []

    var body: some View {
        @Bindable var list = list
        VStack(spacing: 0) {
            if list.isSearching && list.isEmpty {
                ProgressView("Asking your indexers…").frame(maxHeight: .infinity)
            } else if list.visible.isEmpty {
                ContentUnavailableView("No releases", systemImage: "tray",
                                       description: Text(list.message ?? "Your indexers found nothing for this."))
            } else {
                table
            }
            footer
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                @Bindable var model = model
                Toggle("Download only", systemImage: "arrow.down.to.line", isOn: $model.downloadOnly)
                    .help("Adds wait for the service, download the files to this Mac, then delete the item from the service.")
            }
        }
    }

    private var table: some View {
        let rows = list.visible.enumerated().map { SourceRowValues(group: $1, rank: $0, scope: nil) }
        let sorted = order.isEmpty ? rows : rows.sorted(using: order)
        return Table(sorted, selection: $selection, sortOrder: $order) {
            TableColumn("Release", value: \.name) { row in
                Text(row.name).lineLimit(1).help(row.group.title)
                    .opacity(list.busy.contains(row.id) ? 0.5 : 1)
            }
            .width(min: 260, ideal: 440)
            TableColumn("Format") { row in
                Text(format(of: row.group)).lineLimit(1)
            }
            .width(min: 60, ideal: 110)
            TableColumn("Size", value: \.size) { row in
                Text(row.size > 0 ? row.size.formatted(.byteCount(style: .file)) : "–").monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            TableColumn("Seeders", value: \.seeders) { row in
                Text(row.seeders >= 0 ? "\(row.seeders)" : "–").monospacedDigit()
            }
            .width(min: 44, ideal: 56)
            TableColumn("Age", value: \.published) { row in
                Text(row.published == .distantPast ? "–" : row.published.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
            }
            .width(min: 50, ideal: 64)
            // ⚡ where a service has the torrent cached (`ReleaseList` asks the services that can say).
            TableColumn("Cached on", value: \.cachedCount) { row in
                CachedOn(group: row.group)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Found by") { row in
                Text(row.foundBy).lineLimit(1).foregroundStyle(.secondary).help(row.foundBy)
            }
            .width(min: 80, ideal: 150)
        }
        .contextMenu(forSelectionType: StreamGroup.ID.self) { ids in
            let chosen = list.visible.filter { ids.contains($0.id) }
            if !chosen.isEmpty {
                Button(chosen.count == 1 ? "Add (Automatic)" : "Add \(chosen.count) Releases", systemImage: "plus.circle") {
                    chosen.forEach(add)
                }
                .disabled(!chosen.contains { list.canAdd($0, model: model) })
                Button("Copy Name", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(chosen.map { $0.releaseName ?? $0.title }.joined(separator: "\n"), forType: .string)
                }
            }
        } primaryAction: { ids in
            list.visible.filter { ids.contains($0.id) }.forEach(add)
        }
    }

    @ViewBuilder
    private var footer: some View {
        @Bindable var list = list
        let others = list.bookSplit.other.count
        if others > 0 || list.message != nil || !list.busy.isEmpty {
            HStack(spacing: 8) {
                if !list.busy.isEmpty { ProgressView().controlSize(.small) }
                if let message = list.message { Text(message).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
                Spacer()
                if others > 0 {
                    Toggle(list.showOtherBooks ? "Showing \(others) other results" : "Show \(others) other results",
                           isOn: $list.showOtherBooks)
                        .toggleStyle(.button)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func add(_ group: StreamGroup) {
        guard list.canAdd(group, model: model) else { return }
        list.add(group, model: model)
    }

    /// Book formats, music formats or the game's platform, read from the release's name.
    private func format(of group: StreamGroup) -> String {
        switch list.category {
        case .books, .audiobooks: BookRelease(group).formats.map(\.displayName).joined(separator: " ")
        case .music: MusicFileFormat.formats(in: group.title).map(\.displayName).joined(separator: " ")
        case .games: GamePlatform.of(release: group.title, category: group.category)?.displayName ?? ""
        default: group.traits.resolution ?? ""
        }
    }
}

/// The plugins' answers: one section per plugin, a row per result with Get (to the kind's place).
struct MacPluginResults: View {
    @Environment(AppModel.self) private var model
    let search: PluginSearch

    var body: some View {
        List {
            ForEach(search.answers) { answer in
                Section(answer.call.manifest.name) {
                    if let error = answer.error {
                        Text(error).foregroundStyle(.red)
                    }
                    ForEach(answer.results, id: \.id) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).lineLimit(1)
                                let detail = [row.author, row.format?.uppercased(), row.year.map(String.init),
                                              row.size.map { $0.formatted(.byteCount(style: .file)) }, row.language]
                                    .compactMap { $0 }.joined(separator: " · ")
                                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Spacer()
                            if search.isBusy(row, of: answer.call) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Get", systemImage: "arrow.down.circle") {
                                    search.get(row, from: answer.call, to: nil, using: model)
                                }
                            }
                        }
                    }
                }
            }
            if let message = search.message { Text(message).foregroundStyle(.secondary) }
        }
        .overlay {
            if search.isSearching && search.isEmpty { ProgressView("Asking your plugins…") }
        }
    }
}
