import CoreSpotlight
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedMessage: String?

    private var waitingJobs: Int {
        model.downloadJobs.jobs.filter { $0.state == .waiting }.count
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            SearchView()
                .audiobookMiniPlayer()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            LibraryView()
                .audiobookMiniPlayer()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
            DownloadsView()
                .audiobookMiniPlayer()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .badge(model.downloads.records.filter { $0.state == .downloading }.count + waitingJobs)
                .tag(AppTab.downloads)
            SettingsView()
                .audiobookMiniPlayer()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onOpenURL { model.open($0) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { SpotlightIndex.open(id, using: model) }
        }
        .onContinueUserActivity(SpotlightIndex.viewActivity) { activity in
            SpotlightIndex.open(activity, using: model)
        }
        // "Search in Dove" in Spotlight: search for whatever was typed there.
        .onContinueUserActivity(CSQueryContinuationActionType) { activity in
            model.show(.search(activity.userInfo?[CSSearchQueryString] as? String))
        }
        #if DEBUG
        .task { AudiobookDemo.startIfRequested(on: model) }
        #endif
        // Download-only jobs wait for the service only while Dove is open: iOS has no background polling.
        .onChange(of: scenePhase, initial: true) {
            if scenePhase == .active { model.downloadJobs.startPolling() } else { model.downloadJobs.stopPolling() }
            if scenePhase == .background {
                QuickActions.updateDynamic(using: model)
                WidgetSnapshotWriter.update(using: model)
                BackgroundRefresh.schedule()
            }
        }
        .sheet(item: Binding(get: { model.openedSource }, set: { model.openedSource = $0 })) { batch in
            AddSourceSheet(sources: batch.sources) { result in
                model.openedSource = nil
                if !result.isEmpty { openedMessage = result }
            }
        }
        .sheet(isPresented: Binding(get: { model.audiobook.isPresented }, set: { model.audiobook.isPresented = $0 })) {
            AudiobookPlayerView()
        }
        .alert(openedMessage ?? "", isPresented: Binding(get: { openedMessage != nil }, set: { if !$0 { openedMessage = nil } })) {
            Button("OK") {}
        }
    }
}
