import SwiftUI

/// Which part of an album's or series' page is shown: its own contents (tracks, seasons) or the releases behind
/// them. One setting for every such page, so the Releases tab stays chosen while browsing.
enum PageTab: String {
    case contents
    case releases
}

/// The page's tab switch, centred under the header, the way the Finder and Music place a segmented control.
struct PageTabPicker: View {
    @Binding var tab: PageTab
    /// The first tab's name: "Tracks", "Seasons".
    let contents: String
    /// How many releases the page holds, in the second tab's name.
    let releases: Int

    var body: some View {
        Picker("Show", selection: $tab) {
            Text(contents).tag(PageTab.contents)
            Text(releases == 1 ? "1 Release" : "\(releases) Releases").tag(PageTab.releases)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }
}
