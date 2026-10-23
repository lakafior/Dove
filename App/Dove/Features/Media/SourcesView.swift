import DoveAppCore
import DoveKit
import SwiftUI

/// Sources for one movie or episode, or the season/series packs for a series, from every stream addon.
/// Each row is one release (merged by info hash) with its traits and per-service cache status,
/// and two buttons: play in the user's player, add to the library.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
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
    /// The movie or series these sources are for: what its library items get matched to (`AddedHint`).
    var media: MediaSummary?
    /// "Find a better version": only releases clearly better than what the library holds are listed.
    var upgradeOver: ReleaseQuality?

    @State private var groups: [StreamGroup]?
    @State private var failures: [String] = []
    @State private var showFailures = false
    @State private var showFilters = false
    @State private var status: Status?
    @State private var busy: Set<String> = []
    @State private var isCheckingCache = false
    /// Usenet jobs added by Play, so tapping it again reuses the job (and its service, after a fallback).
    @State private var usenetJobs: [StreamGroup.ID: UsenetJob] = [:]
    /// Plugins that search Movies & TV, asked for this title (not when looking for an upgrade: their rows have no traits).
    @State private var pluginSearch = PluginSearch()
    @State private var tab = ResultsTab.sources
    /// A described filter ("4K DV, no Atmos, under 20 GB") on top of the saved one, for this list only.
    @State private var request: SourceRequest?

    struct UsenetJob: Equatable {
        let backend: BackendID
        let itemID: LibraryItem.ID
    }

    struct Status: Equatable {
        var text: String
        var isError: Bool
        /// nzbdav could not open a compressed archive: Play can send the same NZB to this service instead.
        var fallback: ArchiveFallback?
    }

    struct ArchiveFallback: Equatable {
        let group: StreamGroup.ID
        let target: BackendID
        let failed: UsenetJob
        let player: ExternalPlayer?
    }

    /// The user's configured debrids, for "Recommended" order and Real-Debrid warnings.
    private var ranking: SourceRanking {
        let configured = model.backends.map(\.id)
        return SourceRanking(debrids: model.debridOrder.filter(configured.contains) + configured.filter { !model.debridOrder.contains($0) })
    }

    private var visible: [StreamGroup] {
        let filtered = model.sourceFilter.apply(to: upgrades, ranking: ranking)
        return request?.apply(to: filtered, ranking: ranking) ?? filtered
    }

    /// Every group, or only the better ones when looking for an upgrade.
    private var upgrades: [StreamGroup] {
        guard let upgradeOver else { return groups ?? [] }
        return (groups ?? []).filter { ReleaseQuality(traits: $0.traits).isUpgrade(over: upgradeOver) }
    }

    var body: some View {
        // Filtering and ranking every group is the costly part of a redraw: once per body, not once per use.
        let visible = visible
        return List {
            if let status {
                Text(status.text)
                    .font(.footnote)
                    .foregroundStyle(status.isError ? .red : .primary)
                if let fallback = status.fallback {
                    Button("Play through \(fallback.target.displayName)", systemImage: "play.circle") {
                        playElsewhere(fallback)
                    }
                    .disabled(busy.contains(fallback.group))
                }
            }
            if let upgradeOver, let label = upgradeOver.label {
                Label("Better than yours (\(label))\(groups.map { " · \(upgrades.count) of \($0.count)" } ?? "")", systemImage: "arrow.up.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if tab == .plugins {
                PluginResultsSections(search: pluginSearch, showsState: true)
            } else if let groups {
                if !groups.isEmpty, !groups.contains(where: { $0.librarySource != nil }),
                   model.addonEntries.contains(where: \.isAIOStreams), model.aioStreamsPassword.isEmpty {
                    Label(
                        "These sources can only be played. To see which debrid has them cached and to add them to your library, enter your AIOStreams password in Settings.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if OnDeviceModel.isAvailable, !groups.isEmpty {
                    describeRow(total: groups.count, shown: visible.count, groups: groups)
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
                        groups.isEmpty ? emptyTitle : upgrades.isEmpty ? "Nothing better yet" : "Nothing matches the filters",
                        systemImage: "tray",
                        description: Text(groups.isEmpty ? emptyHint : upgrades.isEmpty ? "None of the \(groups.count) source\(groups.count == 1 ? "" : "s") beats what you have." : "")
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
                        onAdd: group.librarySource.map { _ in { add(group, only: nil) } },
                        places: model.places,
                        defaultPlace: model.place(for: .video),
                        onGet: group.librarySource == nil && group.primary.directFile != nil ? { getFile(group, to: $0) } : nil
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
                HStack { Spacer(); ProgressView("Asking your sources…"); Spacer() }
            }
        }
        .resultsTabs($tab, sources: "Sources", count: groups.map { _ in visible.count }, plugins: pluginSearch)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { downloadOnlyButton }
            ToolbarItem(placement: .primaryAction) { filterButton }
            if !model.newznab.isEmpty {
                ToolbarItem(placement: .primaryAction) { SourcesMenu(category: .media, refresh: groups == nil) }
            }
            if isCheckingCache {
                ToolbarItem(placement: .status) {
                    Label("Checking cache…", systemImage: "bolt").font(.caption).labelStyle(.titleAndIcon)
                }
            }
        }
        // Sources switched here (or on the search screen) ask again.
        .task(id: model.sourceSelection) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showFilters) {
            @Bindable var model = model
            SourceFilterSheet(filter: $model.sourceFilter, groups: groups ?? [])
                .presentationDetents([.medium, .large])
        }
    }

    /// The field for a described filter, or what it understood with a button to clear it.
    @ViewBuilder
    private func describeRow(total: Int, shown: Int, groups: [StreamGroup]) -> some View {
        if let request {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\u{201C}\(request.text)\u{201D}")
                        Text("\(request.summary) · \(shown) of \(total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.footnote)
                Spacer()
                Button("Clear", systemImage: "xmark.circle.fill") {
                    self.request = nil
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
            }
        } else {
            DescribeSourcesField(groups: groups) { request = $0 }
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
        if model.sourceSelection.count(in: .media, indexers: model.newznabIndexers).on == 0 {
            return "Every source is off. Turn one on in Sources."
        }
        return scope == nil ? "" : "Your addons found single episodes only. Add them one by one, or try again later."
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

    /// What this list is for, as the shared source logic (`AppModel.sources(for:)`, `add(_:for:only:)`) takes it.
    private var query: SourceQuery {
        SourceQuery(type: type, id: id, searchTitle: searchTitle, scope: scope, media: media)
    }

    @ViewBuilder
    private func menu(for group: StreamGroup) -> some View {
        if canPlay(group) {
            Button(model.playback.playLabel, systemImage: "play") { play(group) }
            PlayInMenu { play(group, in: $0) }
        }
        if let url = group.playURL {
            Button("Copy link", systemImage: "link") { UIPasteboard.general.url = url }
        }
        if group.librarySource == nil, let file = group.primary.directFile {
            Section("Get the file") {
                ForEach(model.places, id: \.self) { place in
                    Button(model.placeName(of: place), systemImage: place.symbol) { getFile(group, to: place) }
                        .disabled(place.isService && !file.isPlain)
                }
            }
        }
        if group.librarySource != nil {
            Section(model.downloadOnly ? "Download only, through" : "Add only to") {
                ForEach(group.addTargets(through: model.router), id: \.self) { backend in
                    let cached = group.cachedBackends().contains(backend)
                    Button(backend.displayName + (cached ? " ⚡" : "")) { add(group, only: backend) }
                }
            }
        }
        Section {
            Text(group.title)
        }
    }

    /// Shows the addons' answer at once, then fills in cache status from TorBox/Offcloud by info hash.
    /// Addons and Dove's own indexers in parallel, only those picked in Sources for Movies & TV; addon results
    /// first, then the indexers'.
    private func load() async {
        searchPlugins()
        let results = await model.sources(for: query)
        groups = results.groups
        failures = results.failures
        guard results.groups.contains(where: { $0.infoHash != nil }), !model.cacheCheckers.isEmpty else { return }
        isCheckingCache = true
        if let checked = await model.checkingCache(results.groups) { groups = checked }
        isCheckingCache = false
    }

    private func searchPlugins() {
        guard upgradeOver == nil else { return }
        let title = PluginTitle(name: searchTitle ?? media?.name ?? self.title, type: type, streamID: id, media: media, scope: scope)
        pluginSearch.search(title.query, category: .media, title: title, media: media, calls: model.plugins.calls(.search, category: .media))
    }

    /// NZBs play through Dove's own nzbdav job when nzbdav is set up: addon play links make players wait
    /// for nzbdav and time out. Everything else plays the addon's link.
    private func playAction(for group: StreamGroup) -> (() -> Void)? {
        canPlay(group) ? { play(group) } : nil
    }

    private func canPlay(_ group: StreamGroup) -> Bool {
        usenetSource(of: group) != nil || group.playURL != nil
    }

    /// nzbdav, or the service an earlier Play sent this release to.
    private func usenetSource(of group: StreamGroup) -> (source: Source, backend: any LibraryBackend)? {
        guard group.kind == .usenet, let source = group.librarySource, source.kind == .nzb,
              let nzbdav = model.backend(.nzbdav) else { return nil }
        let backend = usenetJobs[group.id].flatMap { model.backend($0.backend) } ?? nzbdav
        return (source, backend)
    }

    private func play(_ group: StreamGroup, in player: ExternalPlayer? = nil) {
        if let usenet = usenetSource(of: group) {
            playUsenet(group, source: usenet.source, on: usenet.backend, in: player)
        } else if let url = group.playURL {
            Task { await open(url, in: player) }
        }
    }

    private func playUsenet(_ group: StreamGroup, source: Source, on backend: any LibraryBackend, in player: ExternalPlayer?) {
        busy.insert(group.id)
        status = Status(text: "Preparing in \(backend.id.displayName)…", isError: false)
        Task {
            defer { busy.remove(group.id) }
            do {
                // Kept before waiting: a service that unpacks takes longer than Play waits, and Play again
                // must find the job instead of adding it twice.
                let itemID: LibraryItem.ID
                if let job = usenetJobs[group.id], job.backend == backend.id {
                    itemID = job.itemID
                } else {
                    itemID = try await backend.add(source, category: AddCategory(mediaType: type))
                    usenetJobs[group.id] = UsenetJob(backend: backend.id, itemID: itemID)
                    remember(group, backend: backend.id, itemIDs: [itemID])
                }
                let prepared = try await UsenetPlayback.prepare(source, itemID: itemID, on: backend)
                status = nil
                await open(prepared.url, in: player)
            } catch let error as UsenetPlayback.CompressedArchiveError {
                status = archiveFailure(error, of: group, in: player)
            } catch {
                status = Status(text: error.localizedDescription, isError: true)
            }
        }
    }

    /// The release cannot stream from nzbdav; offer the next Usenet service, which downloads and unpacks it.
    /// Never automatic: the user decides where a release goes.
    private func archiveFailure(_ error: UsenetPlayback.CompressedArchiveError, of group: StreamGroup, in player: ExternalPlayer?) -> Status {
        guard let target = model.compressedArchiveTarget(after: error.backend) else {
            return Status(
                text: error.localizedDescription + " A service that unpacks archives can: turn on Usenet for TorBox, Premiumize or Offcloud in Settings.",
                isError: true
            )
        }
        return Status(
            text: error.localizedDescription + " \(target.displayName) can download and unpack it first, which takes longer.",
            isError: true,
            fallback: ArchiveFallback(
                group: group.id, target: target, failed: UsenetJob(backend: error.backend, itemID: error.itemID), player: player
            )
        )
    }

    /// Sends the release to the fallback service, removes the failed job (best effort), and plays from there.
    private func playElsewhere(_ fallback: ArchiveFallback) {
        guard let group = groups?.first(where: { $0.id == fallback.group }),
              let source = group.librarySource,
              let target = model.backend(fallback.target) else { return }
        if let failedOn = model.backend(fallback.failed.backend) {
            Task { try? await failedOn.delete(fallback.failed.itemID) }
        }
        usenetJobs[group.id] = nil
        playUsenet(group, source: source, on: target, in: fallback.player)
    }

    private func open(_ url: URL, in player: ExternalPlayer?) async {
        do {
            try await model.playback.play([PlayEntry(url: url)], in: player)
        } catch {
            status = Status(text: error.localizedDescription, isError: true)
        }
    }

    /// Services sometimes list a release under a random name: keep the search's name and the title for the library.
    /// A direct file link: downloaded here or to iCloud Drive, or sent to a service that fetches plain links.
    private func getFile(_ group: StreamGroup, to place: FilePlace?) {
        busy.insert(group.id)
        status = nil
        Task {
            defer { busy.remove(group.id) }
            let message = await model.getFile(group.primary, type: type, streamID: id, media: media, to: place)
            status = Status(text: message, isError: !message.hasPrefix("Downloading") && !message.hasPrefix("Sent"))
        }
    }

    private func remember(_ group: StreamGroup, backend: BackendID, itemIDs: [LibraryItem.ID]) {
        model.library.recordAdded(
            AddedHint(releaseName: group.releaseName, media: media),
            backend: backend, itemIDs: itemIDs, infoHash: group.infoHash
        )
    }

    /// Automatic: services that have it cached first, then the user's priority. Or one service only.
    private func add(_ group: StreamGroup, only backend: BackendID?) {
        busy.insert(group.id)
        status = nil
        Task {
            defer { busy.remove(group.id) }
            do {
                status = Status(text: try await model.add(group, for: query, only: backend), isError: false)
            } catch {
                status = Status(text: error.localizedDescription, isError: true)
            }
        }
    }
}

private struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let group: StreamGroup
    let scope: PackScope?
    let isBusy: Bool
    let downloadOnly: Bool
    /// Real-Debrid refusing the name, a pack that looks incomplete.
    let warning: String?
    let onPlay: (() -> Void)?
    let onAdd: (() -> Void)?
    let places: [FilePlace]
    let defaultPlace: FilePlace
    /// Set for a direct file link: nil = the default place for video.
    let onGet: ((FilePlace?) -> Void)?

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
                SourceOriginLine(group: group)
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
                .accessibilityLabel("Play")
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
            if let onGet {
                // A tap goes to the default place for video; a long press picks another.
                Menu {
                    ForEach(places, id: \.self) { place in
                        Button(model.placeName(of: place), systemImage: place.symbol) { onGet(place) }
                    }
                } label: {
                    Group {
                        if isBusy { ProgressView() } else { Image(systemName: defaultPlace.symbol) }
                    }
                    .frame(width: 22, height: 22)
                } primaryAction: {
                    onGet(nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .accessibilityLabel("Download")
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
