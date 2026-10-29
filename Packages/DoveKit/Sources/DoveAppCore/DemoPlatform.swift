#if DEBUG
import DoveKit
import Foundation
import MediaPlayer

/// The platform in demo mode (`DemoMode`): screens, links and artwork go to the real one, but nothing that outlives
/// the run is touched. The Files/Finder location, Spotlight, widgets, the Live Activity and Siri suggestions all
/// belong to the user's real library, and finished downloads land in the demo folder.
@MainActor
final class DemoPlatform: AppPlatform {
    private let wrapped: any AppPlatform

    init(wrapping platform: any AppPlatform) {
        wrapped = platform
    }

    var downloadsDirectory: URL { DoveStorage.applicationSupport.appending(path: "Downloaded") }

    func canOpen(_ url: URL) -> Bool { wrapped.canOpen(url) }
    func open(_ url: URL) async -> Bool { await wrapped.open(url) }
    func show(_ destination: AppModel.Destination) { wrapped.show(destination) }

    func libraryChanged() {}
    func servicesChanged(hasServices: Bool) async {}
    func libraryUpdated(_ app: AppModel) {}
    func accountsUpdated(_ app: AppModel) {}
    func downloadsChanged(_ records: [DownloadRecord]) {}
    func audiobookStarted() {}

    func nowPlayingArtwork(from data: Data) -> MPMediaItemArtwork? { wrapped.nowPlayingArtwork(from: data) }
}
#endif
