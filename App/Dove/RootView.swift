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
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(AppTab.library)
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .badge(model.downloads.records.filter { $0.state == .downloading }.count + waitingJobs)
                .tag(AppTab.downloads)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onOpenURL { model.open($0) }
        // Download-only jobs wait for the service only while Dove is open: iOS has no background polling.
        .onChange(of: scenePhase, initial: true) {
            if scenePhase == .active { model.downloadJobs.startPolling() } else { model.downloadJobs.stopPolling() }
        }
        .sheet(item: Binding(get: { model.openedSource }, set: { model.openedSource = $0 })) { source in
            AddSourceSheet(source: source) { result in
                model.openedSource = nil
                if !result.isEmpty { openedMessage = result }
            }
        }
        .alert(openedMessage ?? "", isPresented: Binding(get: { openedMessage != nil }, set: { if !$0 { openedMessage = nil } })) {
            Button("OK") {}
        }
    }
}
