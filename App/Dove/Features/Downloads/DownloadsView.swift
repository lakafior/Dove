import SwiftUI

/// TODO(stage-1): background URLSession download manager with progress, pause/resume (resumeData) and Files export.
struct DownloadsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "No downloads yet",
                systemImage: "arrow.down.circle",
                description: Text("Files you download to this device will appear here.")
            )
            .navigationTitle("Downloads")
        }
    }
}
