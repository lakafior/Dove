import DoveKit
import SwiftUI

/// Files downloaded to the device: progress, pause and resume, retry, share or open in another app.
/// Finished files also show in Files under On My iPhone › Dove.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?
    @State private var cancelling: DownloadJob?

    private var downloads: DownloadManager { model.downloads }

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
                let pending = model.downloadJobs.jobs.filter { job in
                    if case .downloading = job.state { false } else { true }
                }
                if !pending.isEmpty {
                    Section {
                        ForEach(pending) { JobRow(job: $0, retry: { retry($0) }, cancel: { cancelling = $0 }) }
                    } header: {
                        Text("Download only")
                    } footer: {
                        Text("Dove checks the service while the app is open. The files download, then the item is removed from the service.")
                    }
                }
                let active = downloads.records.filter { $0.state != .finished }
                let finished = downloads.records.filter { $0.state == .finished }
                if !active.isEmpty {
                    Section("In progress") {
                        ForEach(active) { row($0) }
                    }
                }
                if !finished.isEmpty {
                    Section {
                        ForEach(finished) { row($0) }
                    } header: {
                        Text("On this iPhone")
                    } footer: {
                        Text("Also in the Files app: On My iPhone › Dove.")
                    }
                }
            }
            .overlay {
                if downloads.records.isEmpty && model.downloadJobs.jobs.isEmpty {
                    ContentUnavailableView(
                        "No downloads yet",
                        systemImage: "arrow.down.circle",
                        description: Text("Long-press a file in the Library and choose Download to phone.")
                    )
                }
            }
            .navigationTitle("Downloads")
            .confirmationDialog(
                "Stop this download-only job?",
                isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                presenting: cancelling
            ) { job in
                Button("Remove from \(job.backend.displayName)", role: .destructive) { cancel(job, deleteItem: true) }
                Button("Keep in \(job.backend.displayName)") { cancel(job, deleteItem: false) }
            } message: { job in
                Text(job.name)
            }
        }
    }

    private func retry(_ job: DownloadJob) {
        message = nil
        Task { await model.downloadJobs.retry(job.id) }
    }

    private func cancel(_ job: DownloadJob, deleteItem: Bool) {
        Task {
            do {
                try await model.downloadJobs.cancel(job.id, deleteItem: deleteItem)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func row(_ record: DownloadRecord) -> some View {
        DownloadRow(
            record: record,
            fileURL: downloads.fileURL(for: record),
            removesFromService: model.downloadJobs.job(for: record) != nil
        ) { action in
            perform(action, on: record)
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { downloads.remove(record.id) }
        }
    }

    private func perform(_ action: DownloadRow.Action, on record: DownloadRecord) {
        message = nil
        switch action {
        case .pause:
            downloads.pause(record.id)
        case .resume:
            Task {
                do { try await downloads.resume(record.id) } catch { message = error.localizedDescription }
            }
        }
    }
}

private struct DownloadRow: View {
    enum Action { case pause, resume }

    let record: DownloadRecord
    let fileURL: URL?
    /// Part of a download-only job: the item leaves the service once its files are here.
    let removesFromService: Bool
    let perform: (Action) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.localName ?? record.name).font(.subheadline).lineLimit(2)
                if record.state == .downloading || record.state == .paused {
                    if let progress = record.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                HStack(spacing: 8) {
                    BackendBadge(backend: record.backend)
                    Text(detail)
                }
                .font(.caption)
                .foregroundStyle(statusColor)
                if removesFromService {
                    Label("Removed from \(record.backend.displayName) when done", systemImage: "arrow.down.to.line")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch record.state {
        case .downloading:
            Button { perform(.pause) } label: { Image(systemName: "pause.fill") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Pause")
        case .paused:
            Button { perform(.resume) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Resume")
        case .failed:
            Button { perform(.resume) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .accessibilityLabel("Retry")
        case .finished:
            if let fileURL {
                ShareLink(item: fileURL) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Share or open in another app")
            }
        }
    }

    private var detail: String {
        let written = record.bytesWritten.formatted(.byteCount(style: .file))
        let total = record.totalBytes?.formatted(.byteCount(style: .file))
        switch record.state {
        case .downloading:
            return total.map { "\(written) of \($0)" } ?? written
        case .paused:
            return "Paused · " + (total.map { "\(written) of \($0)" } ?? written)
        case .finished:
            return fileURL == nil ? "File removed" : (total ?? written)
        case .failed(let reason):
            return reason
        }
    }

    private var statusColor: Color {
        if case .failed = record.state { return .red }
        return .secondary
    }
}

/// A download-only job that has not started its downloads: waiting for the service, or failed.
private struct JobRow: View {
    let job: DownloadJob
    let retry: (DownloadJob) -> Void
    let cancel: (DownloadJob) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.subheadline).lineLimit(2)
                HStack(spacing: 8) {
                    BackendBadge(backend: job.backend)
                    switch job.state {
                    case .waiting:
                        ProgressView().controlSize(.mini)
                        Text("Waiting for \(job.backend.displayName)")
                    case .failed(let reason):
                        Text(reason).foregroundStyle(.red)
                    case .downloading:
                        EmptyView()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if case .failed = job.state {
                Button { retry(job) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Retry")
            }
        }
        .swipeActions {
            Button("Stop", systemImage: "xmark") { cancel(job) }
                .tint(.red)
        }
    }
}
