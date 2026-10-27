import DoveAppCore
import DoveKit
import SwiftUI

/// Only rows that open a page, each saying its state on the right; no switch or picker lives on this screen.
/// The pages and their sections come from `SettingsCatalog` (shared with the Mac's Settings window). Everything
/// about one service is on that service's page.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var setupPresented = false

    var body: some View {
        NavigationStack {
            Form {
                ForEach(SettingsCatalog(model: model).groups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            if entry.page == .setup {
                                Button { setupPresented = true } label: {
                                    SettingsRow(entry.title, symbol: entry.symbol, color: entry.color,
                                                value: entry.value, light: entry.light)
                                }
                                .tint(.primary)
                            } else {
                                NavigationLink(value: entry.page) {
                                    SettingsRow(entry.title, symbol: entry.symbol, color: entry.color,
                                                value: entry.value, light: entry.light)
                                }
                            }
                        }
                    } header: {
                        Text(group.title)
                    } footer: {
                        if let footer = group.footer { Text(footer) }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsPage.self) { $0.destination }
            // Add service pushes a service by value, so saving its key does not pop the page.
            .navigationDestination(for: BackendID.self) { SettingsPage.service($0).destination }
            .sheet(isPresented: $setupPresented) { SetupWizard() }
        }
    }
}
