import Foundation
import UserNotifications

/// What Dove notifies about. Each can be turned off in Settings › Notifications (this device, UserDefaults);
/// all of them are local notifications posted while Dove runs (no push, no server).
public enum NotificationKind: String, CaseIterable, Identifiable {
    case downloads, downloadOnly, watchlist, liveActivity

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .downloads: "Downloads"
        case .downloadOnly: "Download only"
        case .watchlist: "Watchlist"
        case .liveActivity: "Live Activity"
        }
    }

    public var detail: String {
        switch self {
        case .downloads: "A file finished downloading to this iPhone, or failed."
        case .downloadOnly: "A \"Download only\" item is on this iPhone and removed from its service, or stopped on an error."
        case .watchlist: "A series on your watchlist has new episodes, or a movie is out digitally. Checked when Dove opens."
        case .liveActivity: "Download progress on the Lock Screen and in the Dynamic Island."
        }
    }

    public var symbol: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .downloadOnly: "arrow.down.to.line.circle"
        case .watchlist: "bookmark"
        case .liveActivity: "platter.filled.bottom.iphone"
        }
    }

    /// Live Activities are not notifications: iOS does not ask for them.
    public var needsPermission: Bool { self != .liveActivity }

    private var key: String { "notify.\(rawValue)" }

    /// On unless the user turned it off.
    public var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

public enum LocalNotifications {
    /// Asks iOS once, the first time a kind that is on has something to say.
    public static func askIfNeeded(for kind: NotificationKind) {
        guard kind.isOn, kind.needsPermission else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Posts at once, unless the user turned the kind off (iOS drops it anyway without permission).
    public static func post(_ kind: NotificationKind, id: String, title: String, body: String, thread: String) {
        guard kind.isOn else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

