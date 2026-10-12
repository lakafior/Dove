import DoveKit
import SwiftUI

/// "Automatic" walks the priority list (falling through on any error); "Only to" sends to one service.
/// Used by the app's add sheet and by the share extension, so both behave the same.
struct AddSourceView: View {
    let source: Source
    let router: BackendRouter
    /// Called with the success message, or nil when cancelled. Failures stay on screen to try another service.
    let onClose: (String?) -> Void
    @State private var working: Target?
    @State private var error: String?

    enum Target: Hashable {
        case automatic
        case backend(BackendID)
    }

    private var candidates: [BackendID] { router.candidates(for: source).map(\.id) }

    var body: some View {
        List {
            Section {
                Label {
                    Text(source.displayName).lineLimit(3)
                } icon: {
                    Image(systemName: icon)
                }
            }
            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            if candidates.isEmpty {
                ContentUnavailableView(
                    "No service for this source",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Add a service that accepts \(source.kind.rawValue) sources in Dove's Settings.")
                )
            } else {
                if candidates.count > 1 {
                    Section {
                        row(.automatic) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatic")
                                Text(candidates.map(\.displayName).joined(separator: " → "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Only to") {
                    ForEach(candidates, id: \.self) { id in
                        row(.backend(id)) { Text(id.displayName) }
                    }
                }
            }
        }
        .navigationTitle("Add to library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onClose(nil) }
                    .disabled(working != nil)
            }
        }
    }

    private var icon: String {
        switch source.kind {
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

    private func add(_ target: Target) {
        working = target
        error = nil
        Task {
            defer { working = nil }
            do {
                switch target {
                case .automatic:
                    let result = try await router.add(source)
                    let skipped = result.skipped
                        .map { "\($0.backend.displayName): \($0.error.localizedDescription)" }
                        .joined(separator: "\n")
                    onClose("Added to \(result.backend.displayName)." + (skipped.isEmpty ? "" : "\n\(skipped)"))
                case .backend(let id):
                    guard let backend = router.backends.first(where: { $0.id == id }) else { return }
                    try await backend.add(source)
                    onClose("Added to \(id.displayName).")
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
