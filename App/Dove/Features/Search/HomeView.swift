import DoveKit
import SwiftUI

/// The search tab before a search: what is downloading, what was added lately, what is trending (with a TMDB
/// key), and recent searches. Everything here comes from the library already loaded (or its cache), TMDB's
/// weekly list cached for half a day, and this device's own history: opening the app costs no extra calls.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    let home: HomeModel
    let onSearch: (HomeModel.RecentSearch) -> Void

    private var library: LibraryModel { model.library }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if needsSetup { setupCard }
            activity
            recentlyAdded
            trending
            recentSearches
        }
        .padding(.vertical, 8)
    }

    // MARK: - Setup

    private var needsSetup: Bool {
        model.backends.isEmpty || !model.addonSet.canSearch
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Set up Dove", systemImage: "sparkles").font(.headline)
            if model.backends.isEmpty {
                Text("Add a debrid service (Real-Debrid, TorBox, Offcloud) or nzbdav to keep what you find.")
            }
            if !model.addonSet.canSearch {
                Text("Add a TMDB key or a Stremio addon that can search, so titles can be found here.")
            }
            Button("Open Settings") { model.selectedTab = .settings }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    // MARK: - Activity

    private var phoneDownloads: [DownloadRecord] {
        model.downloads.records.filter { $0.state == .downloading }
    }

    /// Items the services are still fetching (or waiting on the user for), newest first.
    private var serviceActivity: [ShelfItem] {
        library.items.filter { LibraryFilter.Status(of: $0.item.status) == .active }
    }

    @ViewBuilder
    private var activity: some View {
        let downloads = phoneDownloads
        let active = serviceActivity
        if !downloads.isEmpty || !active.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeHeading("In progress")
                VStack(spacing: 0) {
                    if !downloads.isEmpty {
                        Button { model.selectedTab = .downloads } label: {
                            PhoneDownloadsRow(records: downloads)
                        }
                        .buttonStyle(.plain)
                        if !active.isEmpty { Divider().padding(.leading, 52) }
                    }
                    ForEach(Array(active.prefix(4))) { item in
                        NavigationLink(value: item) { ServiceActivityRow(item: item) }
                            .buttonStyle(.plain)
                        if item.id != active.prefix(4).last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
                if active.count > 4 {
                    Button("\(active.count - 4) more in the Library") { model.selectedTab = .library }
                        .font(.footnote)
                        .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Shelves

    @ViewBuilder
    private var recentlyAdded: some View {
        let titles = library.titles
            .sorted { ($0.latestAdded ?? .distantPast) > ($1.latestAdded ?? .distantPast) }
            .prefix(15)
        if !titles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeHeading("Recently added", action: ("Library", { model.selectedTab = .library }))
                PosterShelf {
                    ForEach(Array(titles)) { title in
                        NavigationLink(value: TitleRoute(id: title.id)) {
                            PosterCard(url: title.media?.poster, title: title.name, subtitle: title.coverage ?? title.year)
                                .overlay(alignment: .topTrailing) {
                                    LibraryStatusMark(status: title.status, count: 1).padding(5)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var trending: some View {
        if !home.trending.isEmpty {
            let owned = Set(library.titles.compactMap(\.media?.id))
            VStack(alignment: .leading, spacing: 10) {
                HomeHeading("Trending this week")
                PosterShelf {
                    ForEach(home.trending.prefix(20)) { item in
                        NavigationLink(value: item) {
                            PosterCard(
                                url: item.poster,
                                title: item.name,
                                subtitle: [item.type == .movie ? "Movie" : "Series", item.releaseInfo]
                                    .compactMap { $0 }.joined(separator: " · ")
                            )
                            .overlay(alignment: .topTrailing) {
                                if owned.contains(item.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.white, .green)
                                        .padding(5)
                                        .accessibilityLabel("In your library")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Recent searches

    @ViewBuilder
    private var recentSearches: some View {
        if !home.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeHeading("Recent searches", action: ("Clear", { withAnimation { home.forgetAll() } }))
                VStack(spacing: 0) {
                    ForEach(home.recentSearches) { search in
                        HStack(spacing: 12) {
                            Button { onSearch(search) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: search.scope == .media ? "clock.arrow.circlepath" : "shippingbox")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                    Text(search.text).foregroundStyle(.primary).lineLimit(1)
                                    if search.scope == .other {
                                        Text("Other").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { withAnimation { home.forget(search) } } label: {
                                Image(systemName: "xmark").font(.caption).foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(search.text)")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        if search.id != home.recentSearches.last?.id { Divider().padding(.leading, 50) }
                    }
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Pieces

/// A section title on the home screen, with an optional trailing button ("Library", "Clear").
struct HomeHeading: View {
    let title: String
    var action: (label: String, perform: () -> Void)?

    init(_ title: String, action: (String, () -> Void)? = nil) {
        self.title = title
        self.action = action.map { (label: $0.0, perform: $0.1) }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if let action {
                Button(action.label, action: action.perform).font(.subheadline)
            }
        }
        .padding(.horizontal)
    }
}

/// A row of poster cards that scrolls sideways, aligned with the headings.
struct PosterShelf<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) { content }
                .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
    }
}

/// Artwork with the title under it; the title on a plain card until (or unless) there is artwork.
struct PosterCard: View {
    let url: URL?
    let title: String
    var subtitle: String?
    var width: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CachedImage(url: url) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(6)
                }
            }
            .frame(width: width, height: width * 1.5)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 0.5))
            Text(title).font(.caption.weight(.medium)).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Files downloading to this phone, in one line: how many and how far together.
private struct PhoneDownloadsRow: View {
    let records: [DownloadRecord]

    private var progress: Double? {
        let total = records.compactMap(\.totalBytes).reduce(0, +)
        guard total > 0 else { return nil }
        return Double(records.map(\.bytesWritten).reduce(0, +)) / Double(total)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.and.arrow.forward.inward")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(records.count == 1 ? records[0].name : "\(records.count) files to this phone")
                    .font(.subheadline)
                    .lineLimit(1)
                if let progress {
                    ProgressView(value: progress)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

/// A torrent or job the service is still working on, with its progress when it reports one.
private struct ServiceActivityRow: View {
    let item: ShelfItem

    private var progress: Double? {
        if case .downloading(let progress) = item.item.status { return progress }
        return nil
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.item.status == .awaitingFileSelection ? "checklist" : "icloud.and.arrow.down")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.item.name).font(.subheadline).lineLimit(1)
                HStack(spacing: 6) {
                    BackendBadge(backend: item.item.backend)
                    Text(item.item.status.label).font(.caption).foregroundStyle(.secondary)
                }
                if let progress {
                    ProgressView(value: progress)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}
