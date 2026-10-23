import DoveAppCore
import DoveKit
import SwiftUI

/// "Find a better version" of a release the library holds: where a title page's "Could be better" Find goes. A movie, or
/// one season of a series (asked through its first episode, packs kept).
struct UpgradeRoute: Hashable {
    let media: MediaSummary
    let quality: ReleaseQuality
    /// A series' season, with the stream ID of its first episode; both nil for a movie.
    let season: Int?
    let episodeID: String?
}

/// The sources of an `UpgradeRoute`: the usual table, showing only releases clearly better than what is held.
struct MacUpgradeView: View {
    let route: UpgradeRoute

    var body: some View {
        MacSourcesTable(query: query, upgradeOver: route.quality)
            .navigationTitle(route.season.map { "\(route.media.name) · Season \($0)" } ?? route.media.name)
            .navigationSubtitle("Better versions")
    }

    private var query: SourceQuery {
        if let season = route.season, let episodeID = route.episodeID {
            return SourceQuery(type: .series, id: episodeID, searchTitle: route.media.name, scope: .season(season), media: route.media)
        }
        return SourceQuery(type: .movie, id: route.media.id, searchTitle: route.media.name, media: route.media)
    }
}
