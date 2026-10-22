import DoveAppCore
import DoveKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct DoveApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .environment(delegate.platform.router)
                .task {
                    let model = delegate.model
                    async let accounts: Void = model.refreshAccounts()
                    async let hosts: Void = model.refreshHostLists()
                    await model.loadAddons()
                    // Statuses are refreshed on launch (iOS gives no background polling); the cached list shows
                    // meanwhile. After the addons: new titles are matched through them.
                    await model.library.start(using: model)
                    await accounts
                    await hosts
                }
        }
    }
}

/// Owns the model so a relaunch for background downloads finds the session already recreated.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let platform: IOSPlatform
    let model: AppModel

    override init() {
        platform = IOSPlatform()
        model = AppModel(platform: platform)
        super.init()
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Download notices show as banners while Dove is open too (`DownloadAlerts`).
        UNUserNotificationCenter.current().delegate = self
        BackgroundRefresh.register(model: model)
        // Artwork has its own disk cache (`ImageCache`); this one serves the rest of URLSession.shared.
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 50 * 1024 * 1024)
        return true
    }

    /// Quick Actions arrive through the scene delegate; one that launched Dove comes with the scene's options.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem { QuickActions.perform(item.type) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
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

extension AppDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tap on a download notice opens the Downloads tab.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.threadIdentifier == DownloadNotices.thread else { return }
        await showDownloads()
    }

    @MainActor
    private func showDownloads() {
        model.show(.downloads)
    }
}
