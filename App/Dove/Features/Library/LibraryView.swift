import DoveKit
import SwiftUI

/// Debrid and Usenet live in separate segments because their statuses mean different things.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var segment: Segment = .debrid
    @State private var selectedBackend: BackendID?
    @State private var items: [LibraryItem] = []
    @State private var errorMessage: String?

    enum Segment: String, CaseIterable, Identifiable {
        case debrid = "Debrid"
        case usenet = "Usenet"
        var id: String { rawValue }
    }

    private var visibleBackends: [any LibraryBackend] {
        model.backends(usenet: segment == .usenet)
    }

    private var currentBackend: (any LibraryBackend)? {
        visibleBackends.first { $0.id == selectedBackend } ?? visibleBackends.first
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                ForEach(items) { item in
                    NavigationLink(value: item) { LibraryRow(item: item) }
                }
                .onDelete(perform: delete)
            }
            .overlay {
                if currentBackend == nil {
                    ContentUnavailableView(
                        "Nothing configured",
                        systemImage: "key",
                        description: Text("Add an API key in Settings.")
                    )
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: LibraryItem.self) { item in
                LibraryItemView(item: item)
            }
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    Picker("Type", selection: $segment) {
                        ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if visibleBackends.count > 1 {
                        Picker("Service", selection: $selectedBackend) {
                            ForEach(visibleBackends.map { $0.id }, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                        }
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .background(.bar)
            }
            .refreshable { await load() }
            .task(id: "\(segment.rawValue)-\(currentBackend?.id.rawValue ?? "none")") { await load() }
        }
    }

    private func load() async {
        guard let backend = currentBackend else {
            items = []
            return
        }
        do {
            items = try await backend.items()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(at offsets: IndexSet) {
        guard let backend = currentBackend else { return }
        let ids = offsets.map { items[$0].id }
        items.remove(atOffsets: offsets)
        Task {
            for id in ids {
                do { try await backend.delete(id) } catch { errorMessage = error.localizedDescription }
            }
        }
    }
}

struct LibraryRow: View {
    let item: LibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name).lineLimit(2)
            HStack(spacing: 8) {
                Text(item.status.label)
                if let size = item.size {
                    Text(size.formatted(.byteCount(style: .file)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct LibraryItemView: View {
    @Environment(AppModel.self) private var model
    let item: LibraryItem
    @State private var detail: LibraryItem?
    @State private var message: String?

    private var files: [LibraryFile] { (detail ?? item).files }

    var body: some View {
        List {
            if let message { Text(message).font(.footnote) }
            ForEach(files) { file in
                VStack(alignment: .leading) {
                    Text(file.name)
                    if let size = file.size {
                        Text(size.formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contextMenu {
                    Button("Copy link", systemImage: "link") { copyLink(file) }
                    // TODO(stage-1): "Download to phone" via the background download manager.
                }
            }
        }
        .overlay {
            if detail == nil && files.isEmpty && message == nil { ProgressView() }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadDetail() }
        .task { await loadDetail() }
    }

    /// Some backends (Real-Debrid) only return files from a per-item call.
    private func loadDetail() async {
        guard let backend = model.backend(item.backend) else { return }
        do {
            detail = try await backend.item(item.id)
        } catch {
            message = error.localizedDescription
        }
    }

    private func copyLink(_ file: LibraryFile) {
        guard let backend = model.backend(item.backend) else { return }
        Task {
            do {
                let request = try await backend.downloadRequest(itemID: item.id, fileID: file.id)
                UIPasteboard.general.url = request.url
                message = "Link copied."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

extension LibraryItem.Status {
    var label: String {
        switch self {
        case .queued: "⏳ Queued"
        case .downloading(let progress): "⏳ \(Int(progress * 100))%"
        case .ready: "⚡ Ready"
        case .failed(let reason): "❌ \(reason)"
        }
    }
}
