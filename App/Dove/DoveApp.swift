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

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == AppModel.downloadSessionID else { return completionHandler() }
        model.downloads.backgroundEventsCompletion = completionHandler
    }
}
