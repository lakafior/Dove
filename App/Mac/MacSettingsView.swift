import DoveAppCore
import DoveKit
import SwiftUI

/// The Settings window (⌘,): the iPhone's Settings pages in a sidebar, like System Settings. Pages and sections come
/// from `SettingsCatalog`; each page is the same form as on iOS.
struct MacSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var page: SettingsPage?

    var body: some View {
        let groups = SettingsCatalog(model: model).groups
        NavigationSplitView {
            List(selection: $page) {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.entries) { entry in
                            HStack {
                                Label {
                                    Text(entry.title)
                                } icon: {
                                    SettingsIcon(symbol: entry.symbol, color: entry.color)
                                }
                                Spacer()
                                if let light = entry.light { StatusLight(color: light) }
                            }
                            .tag(entry.page)
                        }
                    }
                }
                Text("Dove \(SettingsCatalog.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            NavigationStack {
                (page ?? groups.first?.entries.first?.page ?? .routing).destination
                    .formStyle(.grouped)
                    .navigationDestination(for: SettingsPage.self) { $0.destination.formStyle(.grouped) }
                    .navigationDestination(for: BackendID.self) { SettingsPage.service($0).destination.formStyle(.grouped) }
            }
            // A new page starts its own stack.
            .id(page)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 640)
    }
}
