import DoveKit
import SwiftUI

/// Where adds go: the debrid order for torrents and links, the Usenet order for NZBs, private trackers' torrents,
/// and a speed test that can reorder both lists. Drag to reorder; "Automatic" adds try the services top to bottom.
struct RoutingSettingsView: View {
    @Environment(AppModel.self) private var model

    private var speed: SpeedTestModel { model.speed }

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                ForEach(model.debridOrder) { id in
                    ServiceOrderRow(id: id, skipped: debridSkip(id))
                }
                .onMove { model.debridOrder.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("Torrents and links")
            } footer: {
                Text("Services without a key are skipped.")
            }

            Section {
                ForEach(model.usenetOrder) { id in
                    ServiceOrderRow(id: id, skipped: usenetSkip(id))
                }
                .onMove { model.usenetOrder.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                Text("NZBs")
            } footer: {
                Text("Services that are not set up, or debrids with Usenet off on their page, are skipped.")
            }

            Section {
                if model.canChoosePrivateTrackers {
                    Picker("Send to", selection: $model.privateTrackersChoice) {
                        ForEach([PrivateTrackerTarget.debridLink, .torBox, .both]) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.menu)
                } else {
                    LabeledContent("Send to", value: privateTrackerValue)
                }
            } header: {
                Text("Private trackers")
            } footer: {
                Text(privateTrackersFooter)
            }

            Section {
                Button {
                    Task { await speed.run(testable, using: model) }
                } label: {
                    Label(speed.isRunning ? "Testing…" : "Test speed", systemImage: "speedometer")
                }
                .disabled(speed.isRunning || testable.isEmpty)
                Button {
                    withAnimation {
                        model.debridOrder = SpeedTest.ordered(model.debridOrder, by: samples(for: model.debridOrder, skip: debridSkip))
                        model.usenetOrder = SpeedTest.ordered(model.usenetOrder, by: samples(for: model.usenetOrder, skip: usenetSkip))
                    }
                } label: {
                    Label("Order by speed", systemImage: "arrow.up.arrow.down")
                }
                .disabled(speed.isRunning || !testable.contains { speed.samples[$0] != nil })
            } header: {
                Text("Speed")
            } footer: {
                Text("Downloads the start of a big file from each service's library (up to 150 MB or 10 seconds) over Wi-Fi, the network your TV uses. Results stay on this iPhone. Ordering by speed is up to you. A release cached on some services goes to the first of those in this order; one cached nowhere goes to the first service.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Order and fallback")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func debridSkip(_ id: BackendID) -> String? {
        model.isConfigured(id) ? nil : "No key"
    }

    private func usenetSkip(_ id: BackendID) -> String? {
        if !model.isConfigured(id) { return id == .nzbdav ? "Not set up" : "No key" }
        return model.usenetEnabled(id) ? nil : "Usenet off"
    }

    /// Every service taking part in either list, each once, in the order they first appear.
    private var testable: [BackendID] {
        var seen = Set<BackendID>()
        return (model.debridOrder.filter { debridSkip($0) == nil } + model.usenetOrder.filter { usenetSkip($0) == nil })
            .filter { seen.insert($0).inserted }
    }

    private func samples(for order: [BackendID], skip: (BackendID) -> String?) -> [BackendID: SpeedSample] {
        speed.samples.filter { id, _ in order.contains(id) && skip(id) == nil }
    }

    private var privateTrackerValue: String {
        let services = model.privateTrackerServices
        return services.isEmpty ? "No seeding service" : services.map(\.displayName).joined(separator: ", ")
    }

    private var privateTrackersFooter: String {
        let services = model.privateTrackerServices
        guard !services.isEmpty else {
            return "Torrents from private trackers need a service that seeds: Debrid-Link, or TorBox on a paid plan."
        }
        var text = "Torrents from private trackers go only to services that seed, so your ratio holds."
        if services.contains(.torBox), let plan = model.torBoxPlan.plan, let time = plan.seedingTimeText {
            text += " TorBox \(plan.name) seeds for \(time)"
            text += plan == .essential ? ": most private trackers ask for 72 hours or more." : "."
        }
        return text
    }
}
