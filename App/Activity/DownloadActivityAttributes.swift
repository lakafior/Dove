import ActivityKit
import DoveKit

/// The Live Activity for phone downloads, shared by the app (starts and updates it) and `DoveWidgets` (draws it).
/// Everything changes over time, so it all lives in the content state (`DownloadActivitySummary`).
struct DownloadActivityAttributes: ActivityAttributes {
    typealias ContentState = DownloadActivitySummary
}
