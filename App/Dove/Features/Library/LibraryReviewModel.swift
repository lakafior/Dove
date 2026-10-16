import DoveKit
import Foundation
import Observation

/// The library review (`LibraryReview`): new and missing episodes of the series the user keeps, and releases worth
/// replacing. Runs after each library refresh; asks for a series' episode list only when the stored one is older
/// than `EpisodeScheduleStore.maxAge`, so the home screen itself still costs no calls. Never adds anything.
@MainActor
@Observable
final class LibraryReviewModel {
    /// By title ID; titles with nothing to report are left out.
    private(set) var reviews: [String: TitleReview] = [:]
    private(set) var schedules: [String: EpisodeSchedule] = [:]
    private(set) var isRunning = false
    private var dismissals: ReviewDismissals

    private let store = EpisodeScheduleStore(fileURL: URL.applicationSupportDirectory.appending(path: "Dove/library-episodes.json"))
    private static let dismissalsURL = URL.applicationSupportDirectory.appending(path: "Dove/library-review-dismissed.json")
    /// Metadata addons and TMDB answer quickly, but a library can hold dozens of series.
    private static let concurrency = 3

    init() {
        dismissals = ReviewDismissals.load(from: Self.dismissalsURL) ?? ReviewDismissals()
    }

    /// Refreshes stale episode lists of the library's matched series, then reviews every title.
    func run(using app: AppModel) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        schedules = await store.all()
        recompute(app.library.titles)

        let series = app.library.titles.compactMap { $0.type == .series ? $0.media : nil }
        await store.prune(keeping: Set(series.map(\.id)))
        var stale: [MediaSummary] = []
        for media in series where await store.needsRefresh(media.id) { stale.append(media) }
        guard !stale.isEmpty, app.addonSet.canSearch || !app.addonEntries.isEmpty else { return }

        let addons = app.addonSet
        await withTaskGroup(of: (String, MediaDetail?).self) { group in
            var pending = stale[...]
            func next() -> Bool {
                guard let media = pending.popFirst() else { return false }
                group.addTask { (media.id, try? await addons.detail(of: media)) }
                return true
            }
            for _ in 0..<Self.concurrency where next() {}
            for await (id, detail) in group {
                // A failed lookup keeps the old list and is tried again on the next refresh.
                if let detail, !detail.episodes.isEmpty { await record(detail, for: id) }
                _ = next()
            }
        }
        schedules = await store.all()
        recompute(app.library.titles)
    }

    /// The title screen loads the series' metadata anyway: it refreshes the stored list for free.
    func record(_ detail: MediaDetail, for mediaID: String) async {
        guard !detail.episodes.isEmpty else { return }
        let schedule = EpisodeSchedule(detail: detail)
        await store.set(schedule, for: mediaID)
        schedules[mediaID] = schedule
    }

    func recompute(_ titles: [LibraryTitle]) {
        dismissals.keep(only: Set(titles.map(\.id)))
        var reviews: [String: TitleReview] = [:]
        for title in titles {
            let review = review(of: title)
            if !review.isEmpty { reviews[title.id] = review }
        }
        self.reviews = reviews
    }

    /// One title, with pack files the title screen already loaded (exact instead of presumed).
    func review(of title: LibraryTitle, files: [ShelfItem.ID: [LibraryFile]] = [:]) -> TitleReview {
        LibraryReview.review(title, schedule: schedule(for: title), files: files, dismissals: dismissals)
    }

    func schedule(for title: LibraryTitle) -> EpisodeSchedule? {
        title.media.flatMap { schedules[$0.id] }
    }

    // MARK: - Home

    /// Series with new or missing episodes: new ones first (latest air date first), then the rest by name.
    func episodeTitles(in titles: [LibraryTitle]) -> [(title: LibraryTitle, review: TitleReview)] {
        titles.compactMap { title in reviews[title.id].flatMap { $0.hasEpisodes ? (title, $0) : nil } }
            .sorted { a, b in
                switch (a.review.latestAired, b.review.latestAired) {
                case let (x?, y?): x > y
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): a.title.name < b.title.name
                }
            }
    }

    /// Titles held in a weak quality, newest first (the library order).
    func weakTitles(in titles: [LibraryTitle]) -> [(title: LibraryTitle, review: TitleReview)] {
        titles.compactMap { title in reviews[title.id].flatMap { $0.weak.isEmpty ? nil : (title, $0) } }
    }

    // MARK: - Dismissing

    /// Hides the episodes listed now; newer ones still show when they air.
    func dismissEpisodes(of title: LibraryTitle, _ episodes: [Episode]) {
        dismissals.episodes[title.id, default: []].formUnion(episodes.map { LibraryReview.key(season: $0.season, number: $0.number) })
        save(title)
    }

    /// Accepts the quality held now; a change in the library (another release) asks again.
    func dismissQuality(of title: LibraryTitle, _ quality: ReleaseQuality) {
        dismissals.quality[title.id] = quality.label
        save(title)
    }

    /// Brings back everything set aside for a title.
    func restore(_ title: LibraryTitle) {
        dismissals.episodes[title.id] = nil
        dismissals.quality[title.id] = nil
        save(title)
    }

    func hasDismissed(_ title: LibraryTitle) -> Bool {
        dismissals.episodes[title.id] != nil || dismissals.quality[title.id] != nil
    }

    private func save(_ title: LibraryTitle) {
        try? dismissals.save(to: Self.dismissalsURL)
        let review = review(of: title)
        reviews[title.id] = review.isEmpty ? nil : review
    }
}
