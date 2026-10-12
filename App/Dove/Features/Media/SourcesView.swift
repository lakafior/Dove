import DoveKit
import SwiftUI

/// Sources for one movie or episode from every stream addon.
/// A source with a link plays in Infuse; a source with an info hash or NZB can go to the library.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let title: String
    let type: MediaType
    let id: String

    @State private var streams: AddonSet.Streams?
    @State private var selected: StreamCandidate?
    @State private var message: String?
    @State private var showFailures = false

    var body: some View {
        List {
            if let message {
                Text(message).font(.footnote)
            }
            if let streams {
                if streams.candidates.isEmpty {
                    ContentUnavailableView("No sources", systemImage: "tray")
                }
                ForEach(streams.candidates) { candidate in
                    Button { selected = candidate } label: { SourceRow(candidate: candidate) }
                        .tint(.primary)
                }
                if !streams.failures.isEmpty {
                    Section {
                        DisclosureGroup("\(streams.failures.count) sources failed", isExpanded: $showFailures) {
                            ForEach(streams.failures, id: \.self) { Text($0).font(.caption) }
                        }
                    }
                }
            } else {
                HStack { Spacer(); ProgressView("Asking your addons…"); Spacer() }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { streams = await model.addonSet.streams(type: type, id: id) }
        .refreshable { streams = await model.addonSet.streams(type: type, id: id) }
        .confirmationDialog(selected?.title ?? "", isPresented: isPresentingActions, titleVisibility: .visible) {
            if let candidate = selected {
                actions(for: candidate)
            }
        }
    }

    private var isPresentingActions: Binding<Bool> {
        Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })
    }

    @ViewBuilder
    private func actions(for candidate: StreamCandidate) -> some View {
        if let url = candidate.url {
            Button("Play in Infuse") { openInInfuse(url) }
            Button("Copy link") { UIPasteboard.general.url = url }
        }
        if let source = candidate.librarySource {
            Button(candidate.isPack ? "Add whole pack to library" : "Add to library") { add(source) }
        }
    }

    /// Infuse plays any URL handed over with its x-callback scheme; debrid links resolve on the first request.
    private func openInInfuse(_ url: URL) {
        var components = URLComponents(string: "infuse://x-callback-url/play")!
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let infuse = components.url { openURL(infuse) }
    }

    private func add(_ source: Source) {
        message = "Adding…"
        Task {
            do {
                let result = try await model.router.add(source)
                message = "Added to \(result.backend.displayName)."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

private struct SourceRow: View {
    let candidate: StreamCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(candidate.title).font(.subheadline).lineLimit(3)
            HStack(spacing: 6) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .font(.caption2)
            if let size = candidate.size {
                Text(sizeText(size)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var badges: [String] {
        var badges: [String] = []
        if candidate.cached == true { badges.append("⚡") }
        if let resolution = candidate.traits?.resolution { badges.append(resolution) }
        if let service = candidate.service { badges.append(service) }
        switch candidate.kind {
        case .usenet: badges.append("📰")
        case .p2p: badges.append("🧲")
        default: break
        }
        if candidate.isPack { badges.append("pack") }
        return badges
    }

    private func sizeText(_ size: Int64) -> String {
        let file = size.formatted(.byteCount(style: .file))
        guard candidate.isPack, let folder = candidate.folderSize else { return file }
        return "\(file) of \(folder.formatted(.byteCount(style: .file)))"
    }
}
