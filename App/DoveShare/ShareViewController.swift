import DoveKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share sheet entry point. Reads what was shared (a magnet or link, text containing one, a .torrent or .nzb
/// file), then shows the same add screen as the app, with the services and priority from the shared Keychain.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(close: { [weak self] in self?.finish() }, open: { [weak self] url in self?.openInApp(url) })
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

    /// Share extensions have no `UIApplication.shared`; the application is still in the responder chain.
    fileprivate func openInApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url)
                break
            }
            responder = current.next
        }
        finish()
    }
}

@MainActor
@Observable
final class ShareModel {
    enum State {
        case reading
        case ready([Source])
        /// A movie's or series' page: Dove opens it.
        case title(TitleLink)
        /// A direct-download site's file page: Dove downloads it.
        case direct
        case nothing
        case added(String)
    }

    private(set) var state: State = .reading
    private(set) var router: BackendRouter
    @ObservationIgnored private let hostCatalog = HostCatalog(fileURL: HostCatalog.defaultURL)
    let close: () -> Void
    let open: (URL) -> Void

    init(close: @escaping () -> Void, open: @escaping (URL) -> Void) {
        self.open = open
        let keychain = SharedConfiguration.keychain()
        router = BackendRouter(
            backends: SharedConfiguration.backends(from: keychain),
            order: SharedConfiguration.debridOrder(from: keychain),
            usenetOrder: SharedConfiguration.usenetOrder(from: keychain),
            // The extension's own copy (its Caches): no App Group with the app. Refreshed in `read`.
            hostLists: HostCatalog.saved(at: HostCatalog.defaultURL)
        )
        self.close = close
    }

    func read(_ items: [NSExtensionItem]) async {
        let providers = items.flatMap { $0.attachments ?? [] }
        // A direct-download site's file page, with a site set up: Dove fetches it with the user's key.
        if (try? SharedConfiguration.keychain().get(.directSources)) != nil, let md5 = await Self.directMD5(from: providers) {
            state = .direct
            open(URL(string: "dove://direct/\(md5)")!)
            return
        }
        let sources = await Self.sources(from: providers)
        if sources.isEmpty, let link = await Self.titleLink(from: providers) {
            // Straight to the title's screen in Dove: nothing to choose here.
            state = .title(link)
            open(link.deepLink)
            return
        }
        if sources.contains(where: { $0.kind == .hoster }) {
            router.hostLists = await hostCatalog.refresh(router.backends)
        }
        state = sources.isEmpty ? .nothing : .ready(sources)
    }

    func added(_ message: String) {
        state = .added(message)
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            close()
        }
    }

    /// Everything shared, each once: files (they carry the most), then links, then every magnet or link in text.
    private static func sources(from providers: [NSItemProvider]) async -> [Source] {
        var found: [Source] = []
        for provider in providers {
            for (type, isTorrent) in [("org.bittorrent.torrent", true), ("org.newzbin.nzb", false)]
            where provider.hasItemConformingToTypeIdentifier(type) {
                if let data = try? await data(from: provider, type: type) {
                    let name = provider.suggestedName.map { $0.contains(".") ? $0 : $0 + (isTorrent ? ".torrent" : ".nzb") }
                        ?? (isTorrent ? "shared.torrent" : "shared.nzb")
                    found.append(isTorrent ? .torrentFile(data: data, filename: name) : .nzbFile(data: data, filename: name))
                }
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let url = try? await url(from: provider) else { continue }
            if let source = SourceDetector.source(opening: url) { found.append(source) }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                found += SourceDetector.sources(in: text)
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// The md5 of a shared direct-download file page (`…/md5/<md5>`).
    private static func directMD5(from providers: [NSItemProvider]) async -> String? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await url(from: provider), url.scheme?.hasPrefix("http") == true,
               let md5 = DirectSource.md5(in: url) { return md5 }
        }
        return nil
    }

    /// A movie's or series' page among the shared links or text (IMDb, Apple TV, Letterboxd…).
    private static func titleLink(from providers: [NSItemProvider]) async -> TitleLink? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await url(from: provider), let link = TitleLink(url: url) { return link }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String,
               let link = TitleLink.first(in: text) { return link }
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
            case .ready(let sources):
                AddSourceView(sources: sources, router: model.router) { message in
                    if let message { model.added(message) } else { model.close() }
                }
            case .title, .direct:
                ProgressView("Opening in Dove…").navigationTitle("Dove")
            case .nothing:
                ContentUnavailableView(
                    "Nothing to add",
                    systemImage: "questionmark.circle",
                    description: Text("Share a magnet, a link, a .torrent or .nzb file, or a movie's page (IMDb, Apple TV, Letterboxd…).")
                )
                .toolbar { Button("Close") { model.close() } }
            case .added(let message):
                ContentUnavailableView(message, systemImage: "checkmark.circle.fill")
            }
        }
    }
}
