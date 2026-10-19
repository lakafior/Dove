import DoveKit
import SwiftUI
import WebKit

/// A plugin's site, in Dove: the user searches and browses there (the site's checks run as in Safari; cookies
/// stay in Dove's default web data store). On a page a plugin's `links` recognise, the toolbar
/// offers Download, which fetches the file through the site's API with the user's key. Dove reads no page.
struct SiteBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let start: URL
    /// What the page was opened for: picks the default place for downloads (Settings › Downloads).
    var category: SearchCategory = .books
    /// The book the page was opened for: files it fetches into iCloud Drive are filed and matched as this book.
    var book: BookSummary?
    @State private var page = SiteBrowserPage()
    @State private var message: String?
    @State private var isStarting = false

    /// The plugin that knows this page as a file's, and the file's id.
    private var file: (call: PluginCall, id: String)? {
        page.url.flatMap { model.plugins.link(for: $0) }
    }

    var body: some View {
        NavigationStack {
            SiteWebView(start: start, page: page)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if page.isLoading { ProgressView(value: page.progress).progressViewStyle(.linear) }
                }
                .safeAreaInset(edge: .bottom) {
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                            .onTapGesture { self.message = nil }
                    }
                }
                .navigationTitle(page.url?.host() ?? start.host() ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Back", systemImage: "chevron.backward") { page.webView?.goBack() }
                            .disabled(!page.canGoBack)
                        Button("Forward", systemImage: "chevron.forward") { page.webView?.goForward() }
                            .disabled(!page.canGoForward)
                        Spacer()
                        if let file {
                            // A tap goes to the kind's default place; a long press offers the others.
                            let standard = model.place(for: category.contentKind)
                            Menu {
                                ForEach(model.places, id: \.self) { place in
                                    Button(place.displayName, systemImage: place.symbol) { download(file, to: place) }
                                }
                            } label: {
                                if isStarting {
                                    ProgressView()
                                } else {
                                    Label("Download", systemImage: standard.symbol)
                                }
                            } primaryAction: {
                                download(file, to: standard)
                            }
                            .labelStyle(.titleAndIcon)
                            .buttonStyle(.borderedProminent)
                            .disabled(isStarting)
                        }
                    }
                }
        }
    }

    private func download(_ file: (call: PluginCall, id: String), to place: FilePlace) {
        isStarting = true
        Task {
            message = await model.getFile(from: file.call, id: file.id, kind: category.contentKind, book: book, to: place)
            isStarting = false
        }
    }
}

/// A page to open in `SiteBrowserView` (for `.sheet(item:)`).
struct BrowserRequest: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}

/// What the web view shows, for the toolbar.
@MainActor @Observable
final class SiteBrowserPage {
    var url: URL?
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    @ObservationIgnored weak var webView: WKWebView?
}

private struct SiteWebView: UIViewRepresentable {
    let start: URL
    let page: SiteBrowserPage

    func makeCoordinator() -> Coordinator { Coordinator(page: page) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(webView)
        page.webView = webView
        webView.load(URLRequest(url: start))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        let page: SiteBrowserPage
        private var observations: [NSKeyValueObservation] = []

        init(page: SiteBrowserPage) {
            self.page = page
        }

        /// KVO on the web view's own properties: the URL also changes on in-page navigation (SPA links).
        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.page.url = view.url }
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.page.isLoading = view.isLoading }
                },
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.page.progress = view.estimatedProgress }
                },
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.page.canGoBack = view.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.page.canGoForward = view.canGoForward }
                },
            ]
        }
    }
}
