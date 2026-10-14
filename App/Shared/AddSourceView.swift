import DoveKit
import SwiftUI

/// Sources picked up together (one, or a pasted list of links), for `.sheet(item:)`.
struct SourceBatch: Identifiable {
    let id = UUID()
    var sources: [Source]

    init(_ sources: [Source]) {
        self.sources = sources
    }
}

/// "Automatic" walks the priority list (falling through on any error); "Only to" sends to one service.
/// Used by the app's add sheet and by the share extension, so both behave the same. Takes one source or a list:
/// a list is added one by one, each with its own fallback. Hoster links go only to services that unlock the site
/// (their host lists), take an optional password, and show the file's name and size when Real-Debrid can tell.
struct AddSourceView: View {
    let sources: [Source]
    let router: BackendRouter
    /// Called with the success message, or nil when cancelled. Failures stay on screen to try another service.
    let onClose: (String?) -> Void
    /// The app's "download only" mode. Nil in the share extension, which closes before a download could run.
    var downloadOnly: Binding<Bool>?
    /// Hands an added item to the download-only jobs; returns the message to show.
    var startDownloadOnly: ((BackendID, DoveKit.LibraryItem.ID, Source) async -> String)?
    @State private var working: Target?
    @State private var progress: (done: Int, total: Int)?
    @State private var error: String?
    @State private var password = ""
    @State private var preview: HosterLinkInfo?

    enum Target: Hashable {
        case automatic
        case backend(BackendID)
    }

    private var isBatch: Bool { sources.count > 1 }
    private var hosterLinks: [Source] { sources.filter { $0.kind == .hoster } }

    /// The sources as they will be sent: hoster links carry the password.
    private var prepared: [Source] {
        let password = password.trimmingCharacters(in: .whitespaces)
        guard !password.isEmpty else { return sources }
        return sources.map { source in
            if case .hosterURL(let url, _) = source { return .hosterURL(url, password: password) }
            return source
        }
    }

    /// Services "Automatic" tries for at least one source, in priority order.
    private var automatic: [BackendID] {
        ordered(sources.flatMap { router.candidates(for: $0).map(\.id) })
    }

    /// Every service that takes at least one source, whatever its host list says: a manual pick may try anyway.
    private var manual: [BackendID] {
        ordered(sources.flatMap { router.compatible(with: $0).map(\.id) })
    }

    private func ordered(_ ids: [BackendID]) -> [BackendID] {
        var seen = Set<BackendID>()
        return ids.filter { seen.insert($0).inserted }
    }

    var body: some View {
        List {
            sourceSection
            if !hosterLinks.isEmpty, !manual.isEmpty {
                Section {
                    SecureField("Password (optional)", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await loadPreview() } }
                } footer: {
                    Text(isBatch ? "Sent with every hoster link in the list." : "Only for files the uploader protected with a password.")
                }
            }
            if let downloadOnly, !manual.isEmpty {
                Section {
                    Toggle("Download only", isOn: downloadOnly)
                } footer: {
                    Text("Downloads the files to this iPhone, then removes them from the service.")
                }
            }
            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            if manual.isEmpty {
                ContentUnavailableView(
                    "No service for this source",
                    systemImage: "exclamationmark.triangle",
                    description: Text(sources.contains(where: \.isPrivateTorrent)
                        ? "This torrent is from a private tracker. Only a service that seeds may take it: add Debrid-Link in Dove's Settings."
                        : "Add a service that accepts \(sources.first?.kind.rawValue ?? "these") sources in Dove's Settings.")
                )
            } else {
                if automatic.count > 1 || (isBatch && !automatic.isEmpty) {
                    Section {
                        row(.automatic) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatic")
                                Text(automatic.map(\.displayName).joined(separator: " → "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        if isBatch { Text("Each link goes to the first service that takes it.") }
                    }
                }
                Section {
                    ForEach(manual, id: \.self) { id in
                        row(.backend(id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(id.displayName)
                                if let note = note(for: id) {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Only to")
                } footer: {
                    if automatic.isEmpty, !hosterLinks.isEmpty {
                        Text("None of your services lists \(hostNames). You can still try one.")
                    }
                }
            }
        }
        .navigationTitle(isBatch ? "Add \(sources.count) items" : "Add to library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onClose(nil) }
                    .disabled(working != nil)
            }
        }
        .task { await loadPreview() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var sourceSection: some View {
        if isBatch {
            Section {
                DisclosureGroup {
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                        Label(source.displayName, systemImage: icon(for: source.kind))
                            .font(.footnote)
                            .lineLimit(2)
                    }
                } label: {
                    Label(batchSummary, systemImage: "list.bullet")
                }
                if let progress {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                        Text("Adding \(progress.done) of \(progress.total)…").font(.footnote)
                    }
                }
            }
        } else if let source = sources.first {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preview?.filename ?? source.displayName).lineLimit(3)
                        if let preview {
                            if !preview.available {
                                Text("The hoster says this file is gone, or the password is wrong.")
                                    .font(.caption).foregroundStyle(.red)
                            } else if let size = preview.size {
                                Text([preview.host, size.formatted(.byteCount(style: .file))].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } icon: {
                    Image(systemName: icon(for: source.kind))
                }
            }
        }
    }

    private var batchSummary: String {
        let counts = Dictionary(grouping: sources, by: \.kind).mapValues(\.count)
        let parts: [String] = [
            counts[.hoster].map { "\($0) hoster link\($0 == 1 ? "" : "s")" },
            counts[.torrent].map { "\($0) torrent\($0 == 1 ? "" : "s")" },
            counts[.nzb].map { "\($0) NZB\($0 == 1 ? "" : "s")" },
        ].compactMap { $0 }
        return parts.joined(separator: ", ")
    }

    private var hostNames: String {
        let names = Array(Set(hosterLinks.compactMap { source -> String? in
            if case .hosterURL(let url, _) = source { return url.host() } else { return nil }
        })).sorted()
        return names.count == 1 ? names[0] : "these sites"
    }

    /// Why a service may not take the links: its host list says no, the hoster is down, or the daily limit is used.
    private func note(for id: BackendID) -> String? {
        let verdicts = sources.map { router.verdict(for: $0, on: id) }
        if !isBatch { return verdicts.first?.summary }
        let refused = verdicts.filter { !$0.isWorthTrying }.count
        let unsupported = sources.filter { source in !router.compatible(with: source).contains { $0.id == id } }.count
        let skipped = refused + unsupported
        return skipped > 0 ? "Skips \(skipped) of \(sources.count)" : nil
    }

    private func icon(for kind: SourceKind) -> String {
        switch kind {
        case .torrent: "link.circle"
        case .hoster: "globe"
        case .nzb: "newspaper"
        }
    }

    private func row(_ target: Target, @ViewBuilder label: () -> some View) -> some View {
        Button { add(target) } label: {
            HStack {
                label()
                Spacer()
                if working == target { ProgressView() }
            }
        }
        .disabled(working != nil)
    }

    // MARK: - Actions

    /// One hoster link and a service that can look at it (Real-Debrid): its name and size before adding.
    private func loadPreview() async {
        guard !isBatch, case .hosterURL(let url, _)? = sources.first,
              let checker = router.backends.lazy.compactMap({ $0 as? any HosterChecking }).first else { return }
        let password = password.trimmingCharacters(in: .whitespaces)
        preview = try? await checker.check(url, password: password.isEmpty ? nil : password)
    }

    private func add(_ target: Target) {
        working = target
        error = nil
        let sources = prepared
        Task {
            defer {
                working = nil
                progress = nil
            }
            var added: [(backend: BackendID, ids: [DoveKit.LibraryItem.ID], source: Source)] = []
            var failures: [String] = []
            var skipped: [String] = []
            if sources.count > 1 { progress = (0, sources.count) }
            for (index, source) in sources.enumerated() {
                do {
                    switch target {
                    case .automatic:
                        let result = try await router.add(source)
                        added.append((result.backend, result.itemIDs, source))
                        skipped += result.skipped.map { "\($0.backend.displayName): \($0.error.localizedDescription)" }
                    case .backend(let id):
                        guard let backend = router.backends.first(where: { $0.id == id }) else { return }
                        guard backend.supports(source) else {
                            throw BackendError.unsupportedSource(source.kind)
                        }
                        let ids = try await backend.addAll(source, category: nil, privateTracker: false)
                        added.append((id, ids, source))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    failures.append(isBatch ? "\(source.displayName): \(error.localizedDescription)" : error.localizedDescription)
                }
                if sources.count > 1 { progress = (index + 1, sources.count) }
            }

            guard !added.isEmpty else {
                self.error = failures.joined(separator: "\n")
                return
            }
            var lines: [String] = []
            if downloadOnly?.wrappedValue == true, let startDownloadOnly {
                for entry in added {
                    for id in entry.ids { lines.append(await startDownloadOnly(entry.backend, id, entry.source)) }
                }
                lines = Array(Set(lines)).sorted()
            } else {
                lines.append(summary(of: added.map { ($0.backend, $0.ids.count) }))
            }
            if isBatch, !failures.isEmpty {
                lines.append("Not added (\(failures.count)):")
                lines += failures
            }
            if !isBatch { lines += skipped }
            onClose(lines.joined(separator: "\n"))
        }
    }

    /// "Added to TorBox." / "Added 12 files to Real-Debrid." / "Added 10: TorBox 8, Real-Debrid 2."
    private func summary(of added: [(backend: BackendID, count: Int)]) -> String {
        var byService: [BackendID: Int] = [:]
        var order: [BackendID] = []
        for entry in added {
            if byService[entry.backend] == nil { order.append(entry.backend) }
            byService[entry.backend, default: 0] += entry.count
        }
        let total = byService.values.reduce(0, +)
        if order.count == 1, let only = order.first {
            return total == 1 ? "Added to \(only.displayName)." : "Added \(total) files to \(only.displayName)."
        }
        return "Added \(total): " + order.map { "\($0.displayName) \(byService[$0] ?? 0)" }.joined(separator: ", ") + "."
    }
}
