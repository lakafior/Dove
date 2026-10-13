import DoveKit
import SwiftUI

/// Sources for one movie or episode, or the season/series packs for a series, from every stream addon.
/// Each row is one release (merged by info hash) with its traits and per-service cache status,
/// and two buttons: play in Infuse, add to the library.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let title: String
    let type: MediaType
    let id: String
    /// When set, only whole-season or whole-series packs are listed.
    var scope: PackScope?
    /// What has aired, to flag packs that look incomplete: episodes of the season, or the series' seasons.
    var airedEpisodes: Int?
    var airedSeasons: [Int]?
    /// The plain title, for indexers that cannot search by IMDb ID.
    var searchTitle: String?

    @State private var groups: [StreamGroup]?
    @State private var failures: [String] = []
    @State private var showFailures = false
    @State private var showFilters = false
    @State private var status: Status?
    @State private var busy: Set<String> = []
    @State private var isCheckingCache = false
    /// nzbdav jobs added by Play, so tapping it again reuses the job.
    @State private var usenetJobs: [StreamGroup.ID: LibraryItem.ID] = [:]

    struct Status: Equatable {
        var text: String
        var isError: Bool
    }

    /// The user's configured debrids, for "Recommended" order and Real-Debrid warnings.
    private var ranking: SourceRanking {
        let configured = model.backends.map(\.id)
        return SourceRanking(debrids: model.debridOrder.filter(configured.contains) + configured.filter { !model.debridOrder.contains($0) })
    }

    private var visible: [StreamGroup] {
        model.sourceFilter.apply(to: groups ?? [], ranking: ranking)
    }

    var body: some View {
        List {
            if let status {
                Text(status.text)
                    .font(.footnote)
                    .foregroundStyle(status.isError ? .red : .primary)
            }
            if let groups {
                if !groups.isEmpty, !groups.contains(where: { $0.librarySource != nil }),
                   model.addonEntries.contains(where: \.isAIOStreams), model.aioStreamsPassword.isEmpty {
                    Label(
                        "These sources can only be played. To see which debrid has them cached and to add them to your library, enter your AIOStreams password in Settings.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if model.sourceFilter.isActive, !groups.isEmpty {
                    Button {
                        showFilters = true
                    } label: {
                        Label("Showing \(visible.count) of \(groups.count) · filters on", systemImage: "line.3.horizontal.decrease")
                            .font(.footnote)
                    }
                }
                if visible.isEmpty {
                    ContentUnavailableView(
                        groups.isEmpty ? emptyTitle : "Nothing matches the filters",
                        systemImage: "tray",
                        description: Text(groups.isEmpty ? emptyHint : "")
                    )
                }
                ForEach(visible) { group in
                    SourceRow(
                        group: group,
                        scope: scope,
                        isBusy: busy.contains(group.id),
                        downloadOnly: model.downloadOnly,
                        warning: [ranking.realDebridWarning(for: group), completenessWarning(for: group)]
                            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                        onPlay: playAction(for: group),
                        onAdd: group.librarySource.map { source in { add(source, of: group, only: nil) } }
                    )
                    .contextMenu { menu(for: group) }
                }
                if !failures.isEmpty {
                    Section {
                        DisclosureGroup("\(failures.count) sources failed", isExpanded: $showFailures) {
                            ForEach(failures, id: \.self) { Text($0).font(.caption) }
                        }
                    }
                }
            } else {
                HStack { Spacer(); ProgressView("Asking your addons…"); Spacer() }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { downloadOnlyButton }
            ToolbarItem(placement: .primaryAction) { filterButton }
            if isCheckingCache {
                ToolbarItem(placement: .status) {
                    Label("Checking cache…", systemImage: "bolt").font(.caption).labelStyle(.titleAndIcon)
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showFilters) {
            SourceFilterSheet(groups: groups ?? [])
                .presentationDetents([.medium, .large])
        }
    }

    private var emptyTitle: String {
        switch scope {
        case .season: "No season packs"
        case .series: "No full-series packs"
        case nil: "No sources"
        }
    }

    private var emptyHint: String {
        scope == nil ? "" : "Your addons found single episodes only. Add them one by one, or try again later."
    }

    private var filterButton: some View {
        Button {
            showFilters = true
        } label: {
            Image(systemName: model.sourceFilter.isActive
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filters")
    }

    /// "Download only": + becomes ↓ — add, download to the phone, remove from the service.
    private var downloadOnlyButton: some View {
        @Bindable var model = model
        return Toggle(isOn: $model.downloadOnly) {
            Label("Download only", systemImage: model.downloadOnly ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .accessibilityHint("Adds download the file to this iPhone, then remove it from the service.")
    }

    private func completenessWarning(for group: StreamGroup) -> String? {
        switch scope {
        case .season: airedEpisodes.flatMap { PackCompleteness.seasonPackWarning(for: group, aired: $0) }
        case .series: airedSeasons.flatMap { PackCompleteness.seriesPackWarning(for: group, airedSeasons: $0) }
        case nil: nil
        }
    }

    /// Which files a download-only add fetches: the episode on screen, every video of a pack, or the movie.
    private var pick: DownloadJob.Pick {
        if scope != nil { return .allVideos }
        if type == .movie { return .largestVideo }
        // Episode IDs are `<series>:<season>:<episode>`.
        let parts = id.split(separator: ":")
        if parts.count >= 3, let season = Int(parts[parts.count - 2]), let episode = Int(parts[parts.count - 1]) {
            return .episode(season: season, episode: episode)
        }
        return .allVideos
    }

    @ViewBuilder
    private func menu(for group: StreamGroup) -> some View {
        if let url = group.playURL {
            Button("Play in Infuse", systemImage: "play") { openInInfuse(url) }
            Button("Copy link", systemImage: "link") { UIPasteboard.general.url = url }
        }
        if let source = group.librarySource {
            Section(model.downloadOnly ? "Download only, through" : "Add only to") {
                ForEach(model.router.candidates(for: source).map(\.id), id: \.self) { backend in
                    let cached = group.cachedBackends().contains(backend)
                    Button(backend.displayName + (cached ? " ⚡" : "")) { add(source, of: group, only: backend) }
                }
            }
        }
        Section {
            Text(group.title)
        }
    }

    /// Shows the addons' answer at once, then fills in cache status from TorBox/Offcloud by info hash.
    /// Addons and Dove's own Usenet indexers in parallel; addon results first, then the indexers'.
    private func load() async {
        let newznab = model.newznab
        let query = NewznabQuery(type: type, id: id, title: searchTitle, wholeSeason: scope != nil)
        async let addonResult = model.addonSet.streams(type: type, id: id)
        async let usenetResult = Self.search(newznab, query)
        let result = await addonResult
        let usenet = await usenetResult?.routed(to: model.usenetBackend)
        let all = StreamGroup.group(result.candidates + (usenet?.candidates ?? []))
        let shown = scope.map { scope in all.filter(scope.matches) } ?? all
        groups = shown
        failures = result.failures + (usenet?.failures ?? [])
        let checkers = model.cacheCheckers
        guard !checkers.isEmpty, shown.contains(where: { $0.infoHash != nil }) else { return }
        isCheckingCache = true
        groups = await CacheChecker.annotate(shown, using: checkers)
        isCheckingCache = false
    }

    private static func search(_ newznab: NewznabSearch, _ query: NewznabQuery?) async -> NewznabSearch.Results? {
        guard let query else { return nil }
        return await newznab.search(query)
    }

    /// NZBs play through Dove's own nzbdav job when nzbdav is set up: addon play links make Infuse wait
    /// for nzbdav and time out. Everything else plays the addon's link.
    private func playAction(for group: StreamGroup) -> (() -> Void)? {
        if group.kind == .usenet, let source = group.librarySource, source.kind == .nzb, let nzbdav = model.backend(.nzbdav) {
            return { playUsenet(group, source: source, on: nzbdav) }
        }
        return group.playURL.map { url in { openInInfuse(url) } }
    }

    private func playUsenet(_ group: StreamGroup, source: Source, on backend: any LibraryBackend) {
        busy.insert(group.id)
        status = Status(text: "Preparing in \(backend.id.displayName)…", isError: false)
        Task {
            defer { busy.remove(group.id) }
            do {
                let prepared = try await UsenetPlayback.prepare(
                    source, itemID: usenetJobs[group.id], category: AddCategory(mediaType: type), on: backend
                )
                usenetJobs[group.id] = prepared.itemID
                status = nil
                openInInfuse(prepared.url)
            } catch {
                status = Status(text: error.localizedDescription, isError: true)
            }
        }
    }

    private func openInInfuse(_ url: URL) {
        if let infuse = Infuse.playURL(for: url) { openURL(infuse) }
    }

    /// Automatic: services that have it cached first, then the user's priority. Or one service only.
    private func add(_ source: Source, of group: StreamGroup, only backend: BackendID?) {
        busy.insert(group.id)
        status = nil
        Task {
            defer { busy.remove(group.id) }
            do {
                // A Torznab result's .torrent link carries the indexer's key: fetch it here, never hand it over.
                let source = try await IndexerTorrent.prepare(source)
                let added: BackendID
                let itemID: LibraryItem.ID
                var skipped: [String] = []
                // NZBs land in nzbdav's `movies` or `tv` folder.
                let category = AddCategory(mediaType: type)
                if let backend, let service = model.backend(backend) {
                    itemID = try await service.add(source, category: category)
                    added = backend
                } else {
                    let result = try await model.router(preferring: group.cachedBackends()).add(source, category: category)
                    added = result.backend
                    itemID = result.itemID
                    skipped = result.skipped.map { "\($0.backend.displayName): \($0.error.localizedDescription)" }
                }
                let message = model.downloadOnly
                    ? await model.startDownloadOnly(itemID, on: added, name: group.folderName ?? group.title, pick: pick)
                    : "Added to \(added.displayName)."
                status = Status(text: ([message] + skipped).joined(separator: "\n"), isError: false)
            } catch {
                status = Status(text: error.localizedDescription, isError: true)
            }
        }
    }
}

private struct SourceRow: View {
    let group: StreamGroup
    let scope: PackScope?
    let isBusy: Bool
    let downloadOnly: Bool
    /// Real-Debrid refusing the name, a pack that looks incomplete.
    let warning: String?
    let onPlay: (() -> Void)?
    let onAdd: (() -> Void)?

    private var traits: StreamTraits { group.traits }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                headline
                tags
                HStack(spacing: 10) {
                    if let size = displaySize {
                        Text(size).monospacedDigit()
                    }
                    services
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                let warnings = group.appleTVWarnings + [warning].compactMap { $0 }
                if !warnings.isEmpty {
                    Label(warnings.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(scope == nil ? group.title : (group.folderName ?? group.title))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(.vertical, 2)
    }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(traits.resolution ?? "?")
                .font(.headline)
            if let quality = traits.quality {
                Text(quality).font(.subheadline)
            }
        }
        .lineLimit(1)
    }

    private var displaySize: String? {
        // A pack's size is the folder; a single episode from a pack shows "episode / pack".
        if scope != nil, let folder = group.folderSize { return folder.formatted(.byteCount(style: .file)) }
        guard let size = group.size else { return nil }
        let file = size.formatted(.byteCount(style: .file))
        if group.isPack, let folder = group.folderSize { return "\(file) / \(folder.formatted(.byteCount(style: .file)))" }
        return file
    }

    private var tags: some View {
        let video = [traits.encode].compactMap { $0 } + traits.visualTags.filter { $0 != "10bit" }
        let audio = traits.audioTags
        let pack = group.packSeasons.isEmpty ? "Pack" : "Pack S" + group.packSeasons.map(String.init).joined(separator: ",")
        var seen = Set<String>()
        let languages = traits.languages.map(LanguageName.code).filter { seen.insert($0).inserted }
        let extra = languages + (group.isPack && scope == nil ? [pack] : [])
        return FlowLayout(spacing: 4) {
            ForEach(video, id: \.self) { Tag(text: $0, style: $0 == "DV" || $0.hasPrefix("HDR") ? .highlight : .plain) }
            ForEach(audio, id: \.self) { Tag(text: $0, style: $0 == "Atmos" ? .highlight : .plain) }
            ForEach(extra, id: \.self) { Tag(text: $0, style: $0 == "PL" ? .accent : .plain) }
        }
    }

    @ViewBuilder
    private var services: some View {
        if !group.availability.isEmpty {
            HStack(spacing: 8) {
                ForEach(group.availability, id: \.service) { availability in
                    HStack(spacing: 2) {
                        if availability.cached == true {
                            Image(systemName: "bolt.fill").foregroundStyle(.yellow)
                        }
                        Text(availability.displayName)
                    }
                    .foregroundStyle(availability.cached == true ? .primary : .secondary)
                }
                if group.kind == .usenet { Text("Usenet") }
                if !group.indexers.isEmpty { Text("via " + group.indexers.joined(separator: " · ")).lineLimit(1) }
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            if let onPlay {
                Button(action: onPlay) {
                    Image(systemName: "play.fill").frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Play in Infuse")
            }
            if let onAdd {
                Button(action: onAdd) {
                    Group {
                        if isBusy { ProgressView() } else { Image(systemName: downloadOnly ? "arrow.down" : "plus") }
                    }
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .accessibilityLabel(downloadOnly ? "Download only" : "Add to library")
            }
        }
    }
}

private struct Tag: View {
    enum Style { case plain, highlight, accent }
    let text: String
    let style: Style

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .foregroundStyle(style == .plain ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.white))
    }

    private var background: AnyShapeStyle {
        switch style {
        case .plain: AnyShapeStyle(.quaternary)
        case .highlight: AnyShapeStyle(Color.purple)
        case .accent: AnyShapeStyle(Color.red)
        }
    }
}

/// Wraps tags onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
