import DoveKit
import Foundation
import MediaPlayer

/// What the app's models need from the platform they run on: system services that differ between iOS and macOS,
/// and the integrations the app keeps current (Files, Spotlight, widgets, the Live Activity). Each app passes its
/// own to `AppModel(platform:)`; the models never import UIKit or AppKit.
@MainActor
public protocol AppPlatform: AnyObject {
    /// Where finished downloads go (iOS: Documents, shown in Files).
    var downloadsDirectory: URL { get }

    /// Whether an app takes links with this URL's scheme (players: `infuse://`, `vlc-x-callback://`…).
    func canOpen(_ url: URL) -> Bool
    /// Opens a URL in another app; false when nothing opened it.
    func open(_ url: URL) async -> Bool

    /// Siri, Spotlight, widgets, notifications and links send the user to a screen; the app routes it.
    func show(_ destination: AppModel.Destination)

    /// The services' item lists or their kinds changed (the Files location re-reads them).
    func libraryChanged()
    /// Whether any service is set up (the Files location exists only then).
    func servicesChanged(hasServices: Bool) async
    /// The library or the watchlist changed: Spotlight and widgets.
    func libraryUpdated(_ app: AppModel)
    /// Plans and premium days changed: widgets.
    func accountsUpdated(_ app: AppModel)
    /// Downloads to this device changed (iOS: the Live Activity).
    func downloadsChanged(_ records: [DownloadRecord])
    /// An audiobook started playing (iOS: a Siri suggestion).
    func audiobookStarted()

    /// Lock screen / Now Playing artwork from image data. Build the image handler outside the main actor: the
    /// system calls it on a background queue.
    func nowPlayingArtwork(from data: Data) -> MPMediaItemArtwork?
}
