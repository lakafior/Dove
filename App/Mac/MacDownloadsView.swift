import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

/// Files downloading to this Mac (Downloads, or iCloud Drive for kinds that go there), as a table. Finished files are
/// the user's: removing one from the list leaves it in its folder; Move to Trash is its own action.
struct MacDownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<DownloadRecord.ID>()
    @State private var message: String?

    private var downloads: DownloadManager { model.downloads }

    var body: some View {
        Group {
            if downloads.records.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                       description: Text("Download a release from the Library: it lands in your Downloads folder."))
            } else {
                table
            }
        }
        .navigationTitle("Downloads")
        .navigationSubtitle(summary)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Show Downloads Folder", systemImage: "folder") {
                    NSWorkspace.shared.open(downloads.directory)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Clear Finished", systemImage: "checkmark.circle") {
                    for record in downloads.records where record.state == .finished {
                        downloads.remove(record.id, deletingFile: false)
                    }
                }
                .help("Removes finished downloads from the list. The files stay where they are.")
                .disabled(!downloads.records.contains { $0.state == .finished })
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") {}
        }
    }

    private var table: some View {
        Table(downloads.records, selection: $selection) {
            TableColumn("Name") { record in
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.name).lineLimit(1)
                    if let subfolder = record.subfolder {
                        Text(subfolder).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .help(record.name)
            }
            .width(min: 240, ideal: 420)
            TableColumn("Source") { record in
                if let backend = record.backend {
                    HStack(spacing: 6) {
                        BackendBadge(backend: backend)
                        Text(backend.displayName)
                    }
                } else {
                    Text(record.plugin != nil ? "Plugin" : "Addon").foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 130)
            TableColumn("Progress") { record in
                DownloadProgressCell(record: record)
            }
            .width(min: 160, ideal: 220)
            TableColumn("Place") { record in
                Text(record.destination.displayName)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Added") { record in
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
            }
            .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: DownloadRecord.ID.self) { ids in
            menu(for: downloads.records.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            for record in downloads.records where ids.contains(record.id) {
                if let url = downloads.fileURL(for: record) { NSWorkspace.shared.open(url) }
            }
        }
        .onDeleteCommand {
            for id in selection { downloads.remove(id, deletingFile: false) }
        }
        // Space pauses what runs in the selection, or resumes what is paused or failed.
        .onKeyPress(.space) {
            let chosen = downloads.records.filter { selection.contains($0.id) }
            guard !chosen.isEmpty else { return .ignored }
            let running = chosen.filter { $0.state == .downloading }
            if running.isEmpty { resume(chosen.filter { $0.state == .paused || $0.isFailed }) } else { running.forEach { downloads.pause($0.id) } }
            return .handled
        }
        .focusedSceneValue(\.pageCommands, MacPageCommands(
            reveal: revealAction,
            remove: selection.isEmpty ? nil : { for id in selection { downloads.remove(id, deletingFile: false) } }
        ))
        // ⌘A. ⌘⌫ is Item › Remove from List: the table never sees it as a key press.
        .onCommand(#selector(NSResponder.selectAll(_:))) { selection = Set(downloads.records.map(\.id)) }
    }

    /// ⇧⌘R: the selected files in the Finder.
    private var revealAction: (() -> Void)? {
        let files = downloads.records.filter { selection.contains($0.id) }.compactMap(downloads.fileURL)
        return files.isEmpty ? nil : { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }

    @ViewBuilder
    private func menu(for records: [DownloadRecord]) -> some View {
        let files = records.compactMap(downloads.fileURL)
        if !files.isEmpty {
            Button("Open", systemImage: "arrow.up.forward.app") { files.forEach { NSWorkspace.shared.open($0) } }
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(files) }
            Divider()
        }
        let running = records.filter { $0.state == .downloading }
        if !running.isEmpty {
            Button("Pause", systemImage: "pause") { running.forEach { downloads.pause($0.id) } }
        }
        let stopped = records.filter { $0.state == .paused || $0.isFailed }
        if !stopped.isEmpty {
            Button(stopped.allSatisfy(\.isFailed) ? "Retry" : "Resume", systemImage: "arrow.clockwise") { resume(stopped) }
        }
        if !records.isEmpty {
            Divider()
            Button("Remove from List", systemImage: "minus.circle") {
                records.forEach { downloads.remove($0.id, deletingFile: false) }
            }
        }
        if !files.isEmpty {
            Button("Move to Trash", systemImage: "trash", role: .destructive) { trash(records) }
        }
        let unfinished = records.filter { $0.state != .finished }
        if !unfinished.isEmpty {
            Button("Cancel Download", systemImage: "xmark", role: .destructive) {
                unfinished.forEach { downloads.remove($0.id) }
            }
        }
    }

    private func resume(_ records: [DownloadRecord]) {
        Task {
            for record in records {
                do { try await downloads.resume(record.id) } catch { message = error.localizedDescription }
            }
        }
    }

    /// The Trash, not a delete: the Finder can put it back.
    private func trash(_ records: [DownloadRecord]) {
        for record in records {
            guard let url = downloads.fileURL(for: record) else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                downloads.remove(record.id, deletingFile: false)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// "2 downloading · 1.2 GB of 4 GB".
    private var summary: String {
        let running = downloads.records.filter { $0.state == .downloading }
        guard !running.isEmpty else {
            let count = downloads.records.count
            return count == 1 ? "1 download" : "\(count) downloads"
        }
        let written = running.reduce(0) { $0 + $1.bytesWritten }
        let total = running.compactMap(\.totalBytes).reduce(0, +)
        let size = total > 0
            ? "\(written.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))"
            : written.formatted(.byteCount(style: .file))
        return "\(running.count) downloading · \(size)"
    }
}

/// A bar while downloading; the state in words otherwise.
private struct DownloadProgressCell: View {
    let record: DownloadRecord

    var body: some View {
        switch record.state {
        case .downloading:
            HStack(spacing: 8) {
                ProgressView(value: record.progress ?? 0).controlSize(.small)
                Text(bytes).font(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
        case .paused:
            Text("Paused · \(bytes)").foregroundStyle(.secondary)
        case .finished:
            Text(record.totalBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "Done")
        case .failed(let reason):
            Text(reason).foregroundStyle(.red).lineLimit(1).help(reason)
        }
    }

    private var bytes: String {
        let written = record.bytesWritten.formatted(.byteCount(style: .file))
        guard let total = record.totalBytes else { return written }
        return "\(written) of \(total.formatted(.byteCount(style: .file)))"
    }
}

private extension DownloadRecord {
    var isFailed: Bool {
        if case .failed = state { true } else { false }
    }
}
