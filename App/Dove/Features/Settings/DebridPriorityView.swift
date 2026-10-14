import DoveKit
import SwiftUI

/// Drag to reorder. "Automatic" adds try the services top to bottom.
struct DebridPriorityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        PriorityList(order: $model.debridOrder) { id in
            model.isConfigured(id) ? nil : "No key"
        } footer: {
            Text("Torrents and links go to the first service. If it fails, Dove tries the next one. Services without a key are skipped.")
        }
    }
}

/// Where NZBs go: nzbdav, TorBox and Offcloud in any order. Debrids count only with their Usenet toggle on.
struct UsenetPriorityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        PriorityList(order: $model.usenetOrder) { id in
            if !model.isConfigured(id) { return id == .nzbdav ? "Not set up" : "No key" }
            return model.backend(id)?.supportedSources.contains(.nzb) == true ? nil : "Usenet off"
        } footer: {
            Text("NZBs go to the first service. If it fails, Dove tries the next one. Services that are not set up, or debrids with Usenet off, are skipped.")
        }
    }
}

private struct PriorityList<Footer: View>: View {
    @Binding var order: [BackendID]
    /// Why a service is skipped, or nil when it takes part.
    let skipped: (BackendID) -> String?
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        List {
            Section {
                ForEach(order) { id in
                    HStack {
                        Text(id.displayName)
                        Spacer()
                        if let reason = skipped(id) {
                            Text(reason).foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                footer()
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Priority")
    }
}
