import SwiftUI
import UIKit

@main
struct DoveApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .task {
                    let model = delegate.model
                    async let accounts: Void = model.services.loadAccounts(model.backends)
                    await model.loadAddons()
                    // Statuses are refreshed on launch (iOS gives no background polling); the cached list shows
                    // meanwhile. After the addons: new titles are matched through them.
                    await model.library.start(using: model)
                    await accounts
                }
        }
    }
}

/// Owns the model so a relaunch for background downloads finds the session already recreated.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Artwork has its own disk cache (`ImageCache`); this one serves the rest of URLSession.shared.
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 50 * 1024 * 1024)
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
