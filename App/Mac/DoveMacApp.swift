import AppKit
import DoveAppCore
import DoveKit
import SwiftUI
import UserNotifications

@main
struct DoveMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: MacAppDelegate

    var body: some Scene {
        Window("Dove", id: "main") {
            MacRootView()
                .environment(delegate.model)
                .environment(delegate.platform.router)
                .task { await delegate.start() }
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            MacSettingsView()
                .environment(delegate.model)
        }
    }
}

/// Owns the model, like iOS's `AppDelegate`: one `AppModel` for the app's whole life, whatever windows are open.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let platform: MacPlatform
    let model: AppModel
    private var started = false

    override init() {
        platform = MacPlatform()
        model = AppModel(platform: platform)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Download notices show as banners while Dove is in front too (`DownloadAlerts`).
        UNUserNotificationCenter.current().delegate = self
    }

    /// Dove keeps running after its window closes (downloads go on); the Dock icon or the menu bar bring it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// What iOS does at launch: addons first (titles are matched through them), then the library from its cache and
    /// the services, account days and host lists.
    func start() async {
        guard !started else { return }
        started = true
        async let accounts: Void = model.refreshAccounts()
        async let hosts: Void = model.refreshHostLists()
        // Download-only jobs wait for their service while Dove runs; on the Mac it keeps running.
        model.downloadJobs.startPolling()
        await model.loadAddons()
        await model.library.start(using: model)
        await accounts
        await hosts
    }
}

extension MacAppDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A click on a download notice opens Downloads.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.content.threadIdentifier == DownloadNotices.thread else { return }
        await showDownloads()
    }

    private func showDownloads() {
        NSApp.activate()
        model.show(.downloads)
    }
}
