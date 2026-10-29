import AppKit
import DoveAppCore
import DoveKit
import SwiftUI
import UserNotifications

@main
struct DoveMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: MacAppDelegate
    @AppStorage(MacMenuBarSettings.showExtra, store: DoveStorage.defaults) private var showMenuBarExtra = true

    var body: some Scene {
        // A window group (not `Window`), so a click on the Dock icon brings it back after it was closed; File › New
        // Window is removed and links go to the open window, so there is one.
        WindowGroup("Dove", id: "main") {
            MacRootView()
                .environment(delegate.model)
                .environment(delegate.platform.router)
                .task { await delegate.start() }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 1100, height: 720)
        // `DoveStorage`: demo mode keeps its view settings apart from the user's.
        .defaultAppStorage(DoveStorage.defaults)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await delegate.model.updates.checkNow() }
                }
                .disabled(delegate.model.updates.isChecking)
            }
            SourceIntakeCommands(model: delegate.model, router: delegate.platform.router)
            SearchCommands(router: delegate.platform.router)
            ViewModeCommands()
            MacShortcutCommands(model: delegate.model, router: delegate.platform.router)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MacMenuBar()
                .environment(delegate.model)
                .environment(delegate.platform.router)
        } label: {
            MacMenuBarLabel()
                .environment(delegate.model)
        }
        .defaultAppStorage(DoveStorage.defaults)

        Settings {
            MacSettingsView()
                .environment(delegate.model)
        }
        .defaultAppStorage(DoveStorage.defaults)
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
        platform.router.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Download notices show as banners while Dove is in front too (`DownloadAlerts`).
        UNUserNotificationCenter.current().delegate = self
        // Services › Add to Dove (`NSServices` in Info.plist).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// The Services menu's "Add to Dove": selected text (a magnet, a link, an info hash) or .torrent/.nzb files from
    /// the Finder open the add sheet.
    @objc func addToDove(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let added = MacSourceIntake.add(urls: files, using: model)
            || pasteboard.string(forType: .string).map { MacSourceIntake.add(text: $0, using: model) } == true
        if added {
            NSApp.activate()
        } else {
            error.pointee = "Dove found no magnet, link, .torrent or .nzb in the selection." as NSString
        }
    }

    /// Dove keeps running after its window closes (downloads go on, unless turned off in Settings); the Dock icon or the menu bar bring it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !MacMenuBarSettings.keepsRunning }

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
