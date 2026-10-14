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

/// Where NZBs go: nzbdav and the debrids with Usenet on, in any order.
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

/// The order, each service's last measured speed, and a speed test that can reorder the list.
private struct PriorityList<Footer: View>: View {
    @Environment(AppModel.self) private var model
    @Binding var order: [BackendID]
    /// Why a service is skipped, or nil when it takes part.
    let skipped: (BackendID) -> String?
    @ViewBuilder let footer: () -> Footer

    private var speed: SpeedTestModel { model.speed }
    private var active: [BackendID] { order.filter { skipped($0) == nil } }

    var body: some View {
        List {
            Section {
                ForEach(order) { id in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(id.displayName)
                            Spacer()
                            if let reason = skipped(id) {
                                Text(reason).foregroundStyle(.secondary)
                            } else if speed.testing == id {
                                ProgressView()
                            }
                        }
                        if skipped(id) == nil {
                            if let failure = speed.failures[id] {
                                Text(failure).font(.caption).foregroundStyle(.red)
                            } else if let summary = speed.summary(id) {
                                Text(summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                footer()
            }

            Section {
                Button {
                    Task { await speed.run(active, using: model) }
                } label: {
                    Label(speed.isRunning ? "Testing…" : "Test speed", systemImage: "speedometer")
                }
                .disabled(speed.isRunning || active.isEmpty)
                Button {
                    withAnimation { order = SpeedTest.ordered(order, by: speed.samples.filter { active.contains($0.key) }) }
                } label: {
                    Label("Order by speed", systemImage: "arrow.up.arrow.down")
                }
                .disabled(speed.isRunning || !active.contains { speed.samples[$0] != nil })
            } header: {
                Text("Speed")
            } footer: {
                Text("Downloads the start of a big file from each service's library (up to 150 MB or 10 seconds) over Wi-Fi, the network your TV uses. Results stay on this iPhone. Ordering by speed is up to you. A release cached on some services goes to the first of those in this order; one cached nowhere goes to the first service.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Priority")
    }
}
