import AppKit
import DoveAppCore
import DoveKit
import SwiftUI
import UniformTypeIdentifiers

/// Sources that arrive from outside a search: a pasted magnet or link, a dropped `.torrent`/`.nzb`, File › Open…, the
/// Dock icon or a `magnet:` link. They all end in `AppModel.openedSource`, which `MacRootView` shows as the add sheet
/// (the iPhone's `AddSourceView`).
@MainActor
enum MacSourceIntake {
    /// Opens the add sheet for what the text holds. False when it holds no source.
    @discardableResult
    static func add(text: String, using model: AppModel) -> Bool {
        let sources = SourceDetector.sources(in: text)
        guard !sources.isEmpty else { return false }
        model.openedSource = SourceBatch(sources)
        return true
    }

    /// Files and links dropped or opened: `.torrent` and `.nzb` files, `magnet:` and web links.
    @discardableResult
    static func add(urls: [URL], using model: AppModel) -> Bool {
        var seen = Set<String>()
        let sources = urls.compactMap { SourceDetector.source(opening: $0) }.filter { seen.insert($0.id).inserted }
        guard !sources.isEmpty else { return false }
        model.openedSource = SourceBatch(sources)
        return true
    }

    /// File › Add from Clipboard: files copied in the Finder first, else the text.
    static func addFromClipboard(using model: AppModel, router: MacRouter) {
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if add(urls: files, using: model) { return }
        if let text = pasteboard.string(forType: .string), add(text: text, using: model) { return }
        router.notice = "The clipboard holds no magnet, link, .torrent or .nzb."
    }

    /// File › Open…: the standard panel for `.torrent` and `.nzb` files.
    static func openFiles(using model: AppModel, router: MacRouter) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["torrent", "nzb"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose .torrent or .nzb files to add to your services."
        guard panel.runModal() == .OK else { return }
        if !add(urls: panel.urls, using: model) { router.notice = "None of these files is a .torrent or .nzb." }
    }
}

/// File › Open… (⌘O) and Add from Clipboard (⇧⌘V).
struct SourceIntakeCommands: Commands {
    let model: AppModel
    let router: MacRouter

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open…") { MacSourceIntake.openFiles(using: model, router: router) }
                .keyboardShortcut("o")
            Button("Add from Clipboard") { MacSourceIntake.addFromClipboard(using: model, router: router) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
        }
    }
}

/// The add sheet for one or several sources: the shared screen with the app's services and priority.
struct MacAddSourceSheet: View {
    @Environment(AppModel.self) private var model
    let sources: [Source]
    let onFinish: (String) -> Void

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            AddSourceView(
                sources: sources,
                router: model.router,
                onClose: { onFinish($0 ?? "") },
                downloadOnly: $model.downloadOnly,
                startDownloadOnly: { backend, itemID, source in
                    await model.startDownloadOnly(itemID, on: backend, name: source.displayName, pick: .allVideos)
                }
            )
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 440, idealHeight: 560)
        // Hoster links route by the services' host lists: load them if a day old.
        .task { if sources.contains(where: { $0.kind == .hoster }) { await model.refreshHostLists() } }
    }
}
