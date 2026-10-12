import DoveKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share sheet entry point. Reads what was shared (a magnet or link, text containing one, a .torrent or .nzb
/// file), then shows the same add screen as the app, with the services and priority from the shared Keychain.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel { [weak self] in self?.finish() }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { await model.read(items) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
@Observable
final class ShareModel {
    enum State {
        case reading
        case ready(Source)
        case nothing
        case added(String)
    }

    private(set) var state: State = .reading
    let router: BackendRouter
    let close: () -> Void

    init(close: @escaping () -> Void) {
        let keychain = SharedConfiguration.keychain()
        router = BackendRouter(
            backends: SharedConfiguration.backends(from: keychain),
            order: SharedConfiguration.debridOrder(from: keychain)
        )
        self.close = close
    }

    func read(_ items: [NSExtensionItem]) async {
        let providers = items.flatMap { $0.attachments ?? [] }
        state = await Self.source(from: providers).map(State.ready) ?? .nothing
    }

    func added(_ message: String) {
        state = .added(message)
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            close()
        }
    }

    /// Files first (they carry the most), then links, then text that contains a magnet or link.
    private static func source(from providers: [NSItemProvider]) async -> Source? {
        for provider in providers {
            for (type, isTorrent) in [("org.bittorrent.torrent", true), ("org.newzbin.nzb", false)]
            where provider.hasItemConformingToTypeIdentifier(type) {
                if let data = try? await data(from: provider, type: type) {
                    let name = provider.suggestedName.map { $0.contains(".") ? $0 : $0 + (isTorrent ? ".torrent" : ".nzb") }
                        ?? (isTorrent ? "shared.torrent" : "shared.nzb")
                    return isTorrent ? .torrentFile(data: data, filename: name) : .nzbFile(data: data, filename: name)
                }
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let url = try? await url(from: provider) else { continue }
            if let source = SourceDetector.source(opening: url) { return source }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let source = SourceDetector.firstSource(in: text) {
                return source
            }
        }
        return nil
    }

    private static func url(from provider: NSItemProvider) async throws -> URL? {
        let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }

    private static func data(from provider: NSItemProvider, type: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
    }
}

struct ShareView: View {
    let model: ShareModel

    var body: some View {
        NavigationStack {
            switch model.state {
            case .reading:
                ProgressView().navigationTitle("Dove")
            case .ready(let source):
                AddSourceView(source: source, router: model.router) { message in
                    if let message { model.added(message) } else { model.close() }
                }
            case .nothing:
                ContentUnavailableView(
                    "Nothing to add",
                    systemImage: "questionmark.circle",
                    description: Text("Share a magnet, a link, or a .torrent or .nzb file.")
                )
                .toolbar { Button("Close") { model.close() } }
            case .added(let message):
                ContentUnavailableView(message, systemImage: "checkmark.circle.fill")
            }
        }
    }
}
