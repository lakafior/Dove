import DoveAppCore
import DoveKit
import SwiftUI

/// What the services are still fetching (queued, downloading, waiting for files to be chosen) and what failed in the
/// last days, from the library list (`ServiceActivity`). While something is active and this page is open, the
/// library is listed again every `ServiceActivity.pollInterval`, like the iPhone's Downloads › On services.
struct MacOnServicesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<ShelfItem.ID>()
    @State private var pendingDelete: [ShelfItem] = []

    private var activity: ServiceActivity {
        ServiceActivity(items: model.library.items, jobs: model.downloadJobs.jobs)
    }

    var body: some View {
        let activity = activity
        let items = activity.active + activity.failed
        Group {
            if items.isEmpty {
                ContentUnavailableView("Nothing in progress", systemImage: "icloud.and.arrow.down",
                                       description: Text("Torrents and NZBs a service is still fetching show up here."))
            } else {
                Table(items, selection: $selection) {
                    TableColumn("Name") { item in
                        Text(item.name).lineLimit(1).help(item.name)
                    }
                    .width(min: 240, ideal: 420)
                    TableColumn("Service") { item in
                        HStack(spacing: 6) {
                            BackendBadge(backend: item.item.backend)
                            Text(item.item.backend.displayName)
                        }
                    }
                    .width(min: 100, ideal: 130)
                    TableColumn("Status") { item in
                        ServiceStatusCell(item: item)
                    }
                    .width(min: 160, ideal: 240)
                    TableColumn("Speed") { item in
                        if let speed = item.item.downloadSpeed {
                            Text("\(speed.formatted(.byteCount(style: .file)))/s").monospacedDigit()
                        }
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("Time left") { item in
                        if let left = item.item.secondsLeft { Text(Self.timeLeft(left)) }
                    }
                    .width(min: 70, ideal: 100)
                    TableColumn("Size") { item in
                        if let size = item.item.size { Text(size.formatted(.byteCount(style: .file))).monospacedDigit() }
                    }
                    .width(min: 70, ideal: 90)
                }
.takesFocusWhenSelected(selection)
                .contextMenu(forSelectionType: ShelfItem.ID.self) { ids in
                    let chosen = items.filter { ids.contains($0.id) }
                    if !chosen.isEmpty {
                        Button(chosen.count == 1 ? "Delete…" : "Delete \(chosen.count) Items…", systemImage: "trash", role: .destructive) {
                            pendingDelete = chosen
                        }
                    }
                }
            }
        }
        .navigationTitle("On services")
        .navigationSubtitle("\(activity.active.count) in progress · \(activity.failed.count) failed in the last 3 days")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.library.refresh(using: model) }
                }
                .keyboardShortcut("r")
                .disabled(model.library.isLoading)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ServiceActivity.pollInterval))
                if !self.activity.active.isEmpty { await model.library.refresh(using: model) }
            }
        }
        .confirmationDialog(
            pendingDelete.count == 1 ? "Delete \(pendingDelete.first?.name ?? "")?" : "Delete \(pendingDelete.count) items?",
            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
        ) {
            Button("Delete", role: .destructive) {
                let items = pendingDelete
                Task { await model.library.delete(items, using: model) }
            }
        } message: {
            Text("They are deleted on the services that hold them.")
        }
    }

    /// "about 12 min", "about 2 h 5 min" (the column says "left").
    private static func timeLeft(_ seconds: TimeInterval) -> String {
        let duration = Duration.seconds(max(60, seconds))
        let text = seconds >= 3600
            ? duration.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
            : duration.formatted(.units(allowed: [.minutes], width: .abbreviated))
        return "about \(text)"
    }
}

private struct ServiceStatusCell: View {
    let item: ShelfItem

    var body: some View {
        switch item.item.status {
        case .downloading(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).controlSize(.small)
                Text("\(Int(progress * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason).foregroundStyle(.red).lineLimit(1).help(reason)
        default:
            Text(item.item.status.label).foregroundStyle(.secondary)
        }
    }
}
