import AppKit
import DoveAppCore
import DoveKit
import Foundation
import MediaPlayer

/// The Mac side of `AppPlatform`. Owns the router the window follows and the Dock icon's download progress. Finder
/// and widgets come in later phases (`docs/macos.md`); until then those hooks do nothing (Spotlight is in).
@MainActor
final class MacPlatform: AppPlatform {
    let router = MacRouter()
    private let dock = DockProgress()

    /// The user's own Downloads folder, not the sandbox container's: the downloads-folder entitlement opens it, and
    /// files there show in the Dock's Downloads stack.
    let downloadsDirectory: URL = {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else { return .downloadsDirectory }
        return URL(filePath: String(cString: home), directoryHint: .isDirectory).appending(path: "Downloads")
    }()

    func canOpen(_ url: URL) -> Bool { NSWorkspace.shared.urlForApplication(toOpen: url) != nil }

    func open(_ url: URL) async -> Bool { NSWorkspace.shared.open(url) }

    func show(_ destination: AppModel.Destination) { router.show(destination) }

    func libraryChanged() {}

    func servicesChanged(hasServices: Bool) async {}

    /// Library titles, books and the watchlist in Spotlight (`SpotlightIndex`, shared with the iPhone).
    func libraryUpdated(_ app: AppModel) {
        SpotlightIndex.update(using: app)
        WidgetSnapshotWriter.update(using: app)
    }

    func accountsUpdated(_ app: AppModel) { WidgetSnapshotWriter.update(using: app) }

    func downloadsChanged(_ records: [DownloadRecord]) { dock.update(records) }

    func audiobookStarted() {}

    func nowPlayingArtwork(from data: Data) -> MPMediaItemArtwork? {
        NSImage(data: data).map(Self.artwork)
    }

    /// Built outside the main actor: the system asks for the image on a background queue, and a closure made in a
    /// main-actor method would trap there.
    nonisolated private static func artwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }
}
