import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// Every release for one movie, episode or pack, as a table: the saved filter applies and "Recommended" order is the
/// starting order (`SourceRanking`); a column header sorts by it instead. Return or a double-click adds
/// (Automatic); the context menu adds to one service. Loading and adding are `AppModel`'s, shared with the iPhone.
struct MacSourcesTable: View {
    @Environment(AppModel.self) private var model
    let query: SourceQuery

    @State private var groups: [StreamGroup]?
    @State private var failures: [String] = []
    @State private var isCheckingCache = false
    @State private var selection = Set<StreamGroup.ID>()
    @State private var order: [KeyPathComparator<SourceRowValues>] = []
    @State private var busy: Set<StreamGroup.ID> = []
    @State private var status: (text: String, isError: Bool)?
    @State private var showFailures = false

    private var ranking: SourceRanking {
        let configured = model.backends.map(\.id)
        return SourceRanking(debrids: model.debridOrder.filter(configured.contains) + configured.filter { !model.debridOrder.contains($0) })
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if let groups {
                let shown = model.sourceFilter.apply(to: groups, ranking: ranking)
                if shown.isEmpty {
                    ContentUnavailableView(
                        groups.isEmpty ? "No sources" : "Everything is filtered out",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(groups.isEmpty
                            ? "Your addons and indexers found nothing for this."
                            : "\(groups.count) releases do not pass the filter saved on your iPhone (Sources › Filters).")
                    )
                } else {
                    table(shown)
                }
            } else {
                ProgressView("Asking your addons and indexers…").frame(maxHeight: .infinity)
            }
            footer
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle("Download only", systemImage: "arrow.down.to.line", isOn: $model.downloadOnly)
                    .help("Adds wait for the service, download the files to this Mac, then delete the item from the service.")
            }
        }
        .task(id: query.id + "\(query.scope.map { "\($0)" } ?? "")") { await load() }
    }

    private func table(_ shown: [StreamGroup]) -> some View {
        let rows = shown.enumerated().map { SourceRowValues(group: $1, rank: $0, scope: query.scope) }
        let sorted = order.isEmpty ? rows : rows.sorted(using: order)
        return Table(sorted, selection: $selection, sortOrder: $order) {
            TableColumn("Release", value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).lineLimit(1)
                    let warnings = row.group.appleTVWarnings
                    if !warnings.isEmpty {
                        Label(warnings.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                .help(row.group.title)
                .opacity(busy.contains(row.id) ? 0.5 : 1)
            }
            .width(min: 220, ideal: 330)
            TableColumn("Res", value: \.resolutionRank) { row in
                Text(row.group.traits.resolution ?? "?").fontWeight(.semibold)
            }
            .width(min: 44, ideal: 56)
            TableColumn("Video") { row in Text(row.video).lineLimit(1).help(row.video) }
                .width(min: 80, ideal: 130)
            TableColumn("Audio") { row in Text(row.audio).lineLimit(1).help(row.audio) }
                .width(min: 80, ideal: 110)
            TableColumn("Size", value: \.size) { row in
                Text(row.size > 0 ? row.size.formatted(.byteCount(style: .file)) : "–").monospacedDigit()
            }
            .width(min: 64, ideal: 74)
            TableColumn("Seeders", value: \.seeders) { row in
                Text(row.seeders >= 0 ? "\(row.seeders)" : "–").monospacedDigit()
            }
            .width(min: 44, ideal: 52)
            TableColumn("Age", value: \.published) { row in
                Text(row.published == .distantPast ? "–" : row.published.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
            }
            .width(min: 50, ideal: 60)
            TableColumn("Cached on", value: \.cachedCount) { row in
                CachedOn(group: row.group)
            }
            .width(min: 90, ideal: 170)
            TableColumn("Found by") { row in
                Text(row.foundBy).lineLimit(1).foregroundStyle(.secondary).help(row.foundBy)
            }
            .width(min: 80, ideal: 130)
        }
        .contextMenu(forSelectionType: StreamGroup.ID.self) { ids in
            let chosen = shown.filter { ids.contains($0.id) }
            if let group = chosen.first, chosen.count == 1 {
                Button("Add (Automatic)", systemImage: "plus.circle") { add(group, only: nil) }
                Menu("Add Only To") {
                    ForEach(group.addTargets(through: model.router), id: \.self) { backend in
                        let cached = group.cachedBackends().contains(backend)
                        Button(cached ? "\(backend.displayName) ⚡" : backend.displayName) { add(group, only: backend) }
                    }
                }
                Divider()
                Button("Copy Name", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(group.releaseName ?? group.title, forType: .string)
                }
            } else if !chosen.isEmpty {
                Button("Add \(chosen.count) Releases (Automatic)", systemImage: "plus.circle") {
                    chosen.forEach { add($0, only: nil) }
                }
            }
        } primaryAction: { ids in
            shown.filter { ids.contains($0.id) }.forEach { add($0, only: nil) }
        }
    }

    @ViewBuilder
    private var footer: some View {
        let parts = [
            status?.text,
            isCheckingCache ? "Checking which services have them cached…" : nil,
        ].compactMap { $0 }
        if !parts.isEmpty || !busy.isEmpty || !failures.isEmpty {
            HStack(spacing: 8) {
                if !busy.isEmpty { ProgressView().controlSize(.small) }
                Text(parts.joined(separator: " · "))
                    .foregroundStyle(status?.isError == true ? .red : .secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                // Addons inside AIOStreams time out often; the list is long, so it waits behind a button.
                if !failures.isEmpty {
                    Button(failures.count == 1 ? "1 source did not answer" : "\(failures.count) sources did not answer") {
                        showFailures = true
                    }
                    .buttonStyle(.link)
                    .popover(isPresented: $showFailures) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(failures, id: \.self) { Text($0).textSelection(.enabled) }
                            }
                            .padding()
                        }
                        .frame(width: 460, height: 260)
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func load() async {
        groups = nil
        let results = await model.sources(for: query)
        groups = results.groups
        failures = results.failures
        guard results.groups.contains(where: { $0.infoHash != nil }), !model.cacheCheckers.isEmpty else { return }
        isCheckingCache = true
        if let checked = await model.checkingCache(results.groups) { groups = checked }
        isCheckingCache = false
    }

    private func add(_ group: StreamGroup, only backend: BackendID?) {
        guard !busy.contains(group.id) else { return }
        busy.insert(group.id)
        status = nil
        Task {
            defer { busy.remove(group.id) }
            do {
                status = (try await model.add(group, for: query, only: backend), false)
            } catch {
                status = (error.localizedDescription, true)
            }
        }
    }
}

/// A table row with plain sortable values; `rank` is the Recommended position.
struct SourceRowValues: Identifiable {
    let group: StreamGroup
    let rank: Int
    let name: String
    let resolutionRank: Int
    let video: String
    let audio: String
    let size: Int64
    let seeders: Int
    let published: Date
    let cachedCount: Int
    let foundBy: String

    var id: StreamGroup.ID { group.id }

    init(group: StreamGroup, rank: Int, scope: PackScope?) {
        self.group = group
        self.rank = rank
        let traits = group.traits
        name = scope == nil ? group.title : (group.folderName ?? group.title)
        resolutionRank = Int(traits.resolution?.prefix { $0.isNumber } ?? "") ?? 0
        video = ([traits.quality, traits.encode].compactMap { $0 } + traits.visualTags.filter { $0 != "10bit" }).joined(separator: " ")
        var seen = Set<String>()
        let languages = traits.languages.map(LanguageName.code).filter { seen.insert($0).inserted }
        audio = (traits.audioTags + languages).joined(separator: " ")
        // A pack's size is its folder.
        size = (scope != nil ? group.folderSize : nil) ?? group.size ?? 0
        seeders = group.seeders ?? -1
        published = group.published ?? .distantPast
        cachedCount = group.availability.filter { $0.cached == true }.count
        foundBy = group.providers.joined(separator: ", ")
    }
}

/// The services a release is known on, ⚡ where it is cached.
private struct CachedOn: View {
    let group: StreamGroup

    var body: some View {
        HStack(spacing: 6) {
            ForEach(group.availability, id: \.service) { availability in
                HStack(spacing: 1) {
                    if availability.cached == true { Image(systemName: "bolt.fill").foregroundStyle(.yellow) }
                    Text(availability.displayName)
                }
                .foregroundStyle(availability.cached == true ? .primary : .secondary)
            }
        }
        .lineLimit(1)
    }
}
