import DoveAppCore
import DoveKit
import SwiftUI

/// The services without a key, kept off the main Settings screen once one is set up.
struct AddServiceView: View {
    @Environment(AppModel.self) private var model

    private var debrids: [BackendID] {
        BackendID.services.filter { $0 != .nzbdav && !model.isConfigured($0) }
    }

    var body: some View {
        Form {
            if !debrids.isEmpty {
                Section {
                    ForEach(debrids, id: \.self) { backend in
                        NavigationLink(value: backend) {
                            SettingsRow(backend.displayName, symbol: backend.settingsSymbol, color: backend.settingsColor)
                        }
                    }
                } header: {
                    Text("Debrid")
                } footer: {
                    Text("Torrents and hoster links. Each takes an API key from your account.")
                }
            }
            if !model.isConfigured(.nzbdav) {
                Section {
                    NavigationLink(value: BackendID.nzbdav) {
                        SettingsRow("nzbdav", symbol: BackendID.nzbdav.settingsSymbol, color: BackendID.nzbdav.settingsColor)
                    }
                } header: {
                    Text("Usenet")
                } footer: {
                    Text("Your own nzbdav or InfiniDysk server. TorBox, Offcloud and Premiumize take NZBs too: turn it on on their page.")
                }
            }
        }
        .overlay {
            if debrids.isEmpty && model.isConfigured(.nzbdav) {
                ContentUnavailableView("Every service is set up", systemImage: "checkmark.circle")
            }
        }
        .navigationTitle("Add service")
        .navigationBarTitleDisplayMode(.inline)
    }
}
