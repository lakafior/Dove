import DoveKit
import SwiftUI

/// Files downloaded to the device: progress, pause and resume, retry, share or open in another app.
/// Finished files also show in Files under On My iPhone › Dove.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?

    private var downloads: DownloadManager { model.downloads }

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.red)
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
                if downloads.records.isEmpty {
                    ContentUnavailableView(
                        "No downloads yet",
                        systemImage: "arrow.down.circle",
                        description: Text("Long-press a file in the Library and choose Download to phone.")
                    )
                }
            }
            .navigationTitle("Downloads")
        }
    }

    private func row(_ record: DownloadRecord) -> some View {
        DownloadRow(record: record, fileURL: downloads.fileURL(for: record)) { action in
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
