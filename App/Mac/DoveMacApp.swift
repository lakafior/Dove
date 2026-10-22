import AppKit
import DoveAppCore
import DoveKit
import SwiftUI

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
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    let platform: MacPlatform
    let model: AppModel
    private var started = false

    override init() {
        platform = MacPlatform()
        model = AppModel(platform: platform)
        super.init()
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
        await model.loadAddons()
        await model.library.start(using: model)
        await accounts
        await hosts
    }
}
