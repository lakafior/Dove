import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var openedMessage: String?

    var body: some View {
        TabView {
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            LibraryView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .badge(model.downloads.records.filter { $0.state == .downloading }.count)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onOpenURL { model.open($0) }
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
