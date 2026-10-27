import DoveAppCore
import DoveKit
import SwiftUI

/// The search tab before a search: how the services are doing, what is downloading, what was added lately, the
/// library's shelves by kind, and recent searches. Everything here comes from the library already loaded (or its
/// cache) and this device's own history: opening the home screen costs no extra calls, and a new kind of content
/// gets its shelf by itself.
struct HomeView: View, @MainActor Equatable {
    @Environment(AppModel.self) private var model
    @Environment(AppRouter.self) private var router
    @State private var setupPresented = false
    let home: HomeModel
    let onSearch: (HomeModel.RecentSearch) -> Void

    /// The search field redraws its screen on every keystroke and hands over a new `onSearch` each time; with
    /// `.equatable()` the home screen skips those redraws. What it shows comes from the models it observes,
    /// which still redraw it when they change.
    static func == (lhs: HomeView, rhs: HomeView) -> Bool { lhs.home === rhs.home }

    private var library: LibraryModel { model.library }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if needsSetup { setupCard }
            servicesStrip
            activity
            episodes
            watchlist
            betterVersions
            recentlyAdded
            shelves
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
                Text("Add a debrid service (Real-Debrid, TorBox, Offcloud, Debrid-Link) or nzbdav to keep what you find.")
            }
            if !model.addonSet.canSearch {
                Text("Add a TMDB key or a Stremio addon that can search, so titles can be found here.")
            }
            Button("Start setup") { setupPresented = true }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
        .fullScreenCover(isPresented: $setupPresented) { SetupWizard() }
    }

    // MARK: - Activity

    private var phoneDownloads: [DownloadRecord] {
        model.downloads.records.filter { $0.state == .downloading }
    }

    /// Items the services are still fetching (or waiting on the user for), newest first.
    private var serviceActivity: [ShelfItem] {
        library.items.filter { LibraryFilter.Status(of: $0.item.status) == .active }
    }

    /// Audiobooks with a saved place that are still in the library, last played first.
    private var listening: [(book: BookTitle, position: AudiobookPosition)] {
        let books = library.books
        return model.audiobook.listening().prefix(3).compactMap { entry in
            books.first { $0.guess.key == entry.key }.map { (book: $0, position: entry.position) }
        }
    }

    @ViewBuilder
    private var activity: some View {
        let downloads = phoneDownloads
        let active = serviceActivity
        let listening = listening
        if !downloads.isEmpty || !active.isEmpty || !listening.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeHeading("In progress")
                VStack(spacing: 0) {
                    ForEach(listening, id: \.book.id) { entry in
                        ListeningRow(book: entry.book, position: entry.position)
                        if entry.book.id != listening.last?.book.id || !downloads.isEmpty || !active.isEmpty {
                            Divider().padding(.leading, 52)
                        }
                    }
                    if !downloads.isEmpty {
                        Button { router.selectedTab = .downloads } label: {
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
                    Button("\(active.count - 4) more in the Library") { router.selectedTab = .library }
                        .font(.footnote)
                        .padding(.horizontal)
                }
            }
        }
    }

    // MARK: - Review

    /// Series with new or missing episodes (`LibraryReviewModel`, refreshed after the library loads).
    @ViewBuilder
    private var episodes: some View {
        let entries = model.review.episodeTitles(in: library.titles)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeHeading(entries.contains { !$0.review.new.isEmpty } ? "New episodes" : "Missing episodes")
                PosterShelf {
                    ForEach(entries, id: \.title.id) { entry in
                        NavigationLink(value: TitleRoute(id: entry.title.id)) {
                            PosterCard(url: entry.title.media?.poster, title: entry.title.name, subtitle: entry.review.episodeSummary)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Hide", systemImage: "eye.slash") {
                                model.review.dismissEpisodes(of: entry.title, entry.review.new + entry.review.missing)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The watchlist, newest first, each with what it is up to; a held title opens from the library.
    @ViewBuilder
    private var watchlist: some View {
        let entries = Array(model.watchlist.list.entries.prefix(15))
        if !entries.isEmpty {
            let titles = library.titles
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Watchlist").font(.title3.bold())
                    Spacer()
                    NavigationLink("See all", value: WatchlistRoute()).font(.subheadline)
                }
                .padding(.horizontal)
                PosterShelf {
                    ForEach(entries) { entry in
                        let card = PosterCard(
                            url: entry.media.poster,
                            title: entry.media.name,
                            subtitle: model.watchlist.status(of: entry, using: model)?.label() ?? entry.media.releaseInfo
                        )
                        Group {
                            if let held = Watchlist.title(for: entry, in: titles) {
                                NavigationLink(value: TitleRoute(id: held.id)) { card }
                            } else {
                                NavigationLink(value: entry.media) { card }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove from Watchlist", systemImage: "bookmark.slash") { model.watchlist.remove(entry) }
                        }
                    }
                }
            }
        }
    }

    /// Titles held in a weak quality (720p, HDTV, AV1…): a tap opens the title, where sources beat it.
    @ViewBuilder
    private var betterVersions: some View {
        let entries = model.review.weakTitles(in: library.titles)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeHeading("Could be better")
                PosterShelf {
                    ForEach(entries, id: \.title.id) { entry in
                        NavigationLink(value: TitleRoute(id: entry.title.id)) {
                            PosterCard(url: entry.title.media?.poster, title: entry.title.name, subtitle: entry.review.qualitySummary, width: 90)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            ForEach(entry.review.weak, id: \.self) { spot in
                                Button("Keep \(spot.season.map { "S\($0) " } ?? "")\(spot.quality.label ?? "")", systemImage: "checkmark") {
                                    model.review.dismissQuality(of: entry.title, spot.quality)
                                }
                            }
                        }
                    }
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
                HomeHeading("Recently added", action: ("Library", { router.selectedTab = .library }))
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

    // MARK: - Shelves

    /// One tile per kind the library holds, with a few of its covers; a tap opens the Library filtered to it.
    @ViewBuilder
    private var shelves: some View {
        let shelves = LibraryShelfSummary.all(in: library, showAdult: model.showAdult)
        if !shelves.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HomeHeading("Your shelves")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(shelves) { shelf in
                        Button {
                            router.libraryCategoryRequest = shelf.category
                            router.selectedTab = .library
                        } label: {
                            ShelfTile(shelf: shelf)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Services

    /// One chip per configured service: a light (online, worth a look, offline) and days of premium left.
    @ViewBuilder
    private var servicesStrip: some View {
        let configured = BackendID.allCases.filter { !$0.isStorage && model.isConfigured($0) }
        if !configured.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(configured, id: \.self) { backend in
                        Button { router.selectedTab = .settings } label: {
                            ServiceChip(
                                name: backend.displayName,
                                light: model.services.light(backend),
                                detail: chipDetail(backend)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
        }
    }

    /// "213 d", "Expired", "Offline"; nothing while all is well and the service has no account to report.
    private func chipDetail(_ backend: BackendID) -> String? {
        if case .offline = model.services.health(of: backend) { return "Offline" }
        guard let account = model.services.accounts[backend] else { return nil }
        guard account.isPremium else { return "Free" }
        if let end = account.premiumUntil, end < .now { return "Expired" }
        return account.daysLeft().map { "\($0) d" }
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
                                    Image(systemName: search.category == .media ? "clock.arrow.circlepath" : search.category.symbolName)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                    Text(search.text).foregroundStyle(.primary).lineLimit(1)
                                    if search.category != .media {
                                        Text(search.category.displayName).font(.caption).foregroundStyle(.secondary)
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

/// An audiobook with a saved place: a tap plays on from there; the context menu takes it off the list (Play then
/// starts from the beginning).
private struct ListeningRow: View {
    @Environment(AppModel.self) private var model
    let book: BookTitle
    let position: AudiobookPosition
    @State private var isStarting = false
    @State private var failure: String?

    private var isCurrent: Bool { model.audiobook.session?.key == book.guess.key }

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                CachedImage(url: book.book?.cover) {
                    Image(systemName: "headphones").foregroundStyle(.tint)
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Listening: \(book.name)").font(.subheadline).lineLimit(1)
                    Text(failure ?? detail)
                        .font(.caption)
                        .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if isStarting {
                    ProgressView()
                } else {
                    Image(systemName: isCurrent && model.audiobook.isPlaying ? "waveform" : "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
        .contextMenu {
            NavigationLink(value: BookRoute(id: book.id)) {
                Label("Show book", systemImage: "book")
            }
            Button("Remove from Listening", systemImage: "xmark.circle", role: .destructive) {
                model.audiobook.clearPosition(for: book.guess.key)
            }
        }
    }

    /// "03 - Chapter, 12:34 · 2 hours ago".
    private var detail: String {
        let name = ((position.trackPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let time = Duration.seconds(position.seconds)
            .formatted(.time(pattern: position.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
        if isCurrent { return "\(name), \(time)" }
        return "\(name), \(time) · \(position.updatedAt.formatted(.relative(presentation: .named)))"
    }

    private func play() {
        if isCurrent {
            if !model.audiobook.isPlaying { model.audiobook.play() }
            model.audiobook.isPresented = true
            return
        }
        isStarting = true
        failure = nil
        Task {
            failure = await model.playAudiobook(book)
            isStarting = false
        }
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
                Text(item.name).font(.subheadline).lineLimit(1)
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

/// A service's name with its light and, for debrids, days of premium left.
private struct ServiceChip: View {
    let name: String
    let light: Color
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            StatusLight(color: light)
            Text(name).font(.footnote.weight(.medium))
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.secondary, in: Capsule())
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A shelf tile: name and count, with up to three covers fanned out (or the kind's symbol).
private struct ShelfTile: View {
    let shelf: LibraryShelfSummary

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: shelf.symbol)
                    .font(.subheadline)
                    .foregroundStyle(.tint)
                Spacer(minLength: 0)
                Text(shelf.category.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("\(shelf.count)").font(.caption).foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            covers
        }
        .padding(12)
        .frame(height: 96)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(shelf.category.title), \(shelf.count)")
        .accessibilityAddTraits(.isButton)
    }

    private var covers: some View {
        let height: CGFloat = 64
        let width = height * shelf.coverRatio
        return ZStack(alignment: .trailing) {
            ForEach(Array(shelf.covers.enumerated().reversed()), id: \.element) { index, url in
                CachedImage(url: url) { Rectangle().fill(.quaternary) }
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .shadow(color: .black.opacity(0.2), radius: 2, x: -1)
                    .offset(x: CGFloat(-index) * width * 0.3)
                    .scaleEffect(1 - CGFloat(index) * 0.08, anchor: .trailing)
            }
        }
        .frame(width: width * (1 + 0.3 * CGFloat(max(shelf.covers.count - 1, 0))), alignment: .trailing)
    }
}
