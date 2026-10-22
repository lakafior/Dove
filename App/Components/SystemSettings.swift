import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The system's own settings, for pages that send the user there (notification permission, Apple Music access).
@MainActor
enum SystemSettings {
    #if os(iOS)
    /// "Open iPhone Settings".
    static let appName = "iPhone Settings"
    /// Who allows or blocks Dove: "iOS blocks Dove's notifications".
    static let systemName = "iOS"
    #else
    static let appName = "System Settings"
    static let systemName = "macOS"
    #endif

    /// Dove's notification settings.
    static func openNotifications() {
        #if os(iOS)
        open(UIApplication.openNotificationSettingsURLString)
        #else
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #endif
    }

    /// Dove's own page (iOS) or Privacy & Security › Media & Apple Music (Mac): where Apple Music access is given back.
    static func openAppleMusicAccess() {
        #if os(iOS)
        open(UIApplication.openSettingsURLString)
        #else
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Media")
        #endif
    }

    private static func open(_ address: String) {
        guard let url = URL(string: address) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}
