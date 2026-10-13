import SwiftUI
import UIKit

@main
struct DoveApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .task { await delegate.model.loadAddons() }
        }
    }
}

/// Owns the model so a relaunch for background downloads finds the session already recreated.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // AsyncImage loads through URLSession.shared; the default cache is too small to hold a library's posters,
        // so they were fetched again on every scroll. Poster CDNs (TMDB, metahub) send long max-age headers.
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == AppModel.downloadSessionID else { return completionHandler() }
        model.downloads.backgroundEventsCompletion = completionHandler
    }
}
