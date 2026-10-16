import SwiftUI
import UIKit
import UserNotifications

/// What Dove notifies about. Each can be turned off in Settings › Notifications (this device, UserDefaults);
/// all of them are local notifications posted while Dove runs (no push, no server).
enum NotificationKind: String, CaseIterable, Identifiable {
    case downloads, downloadOnly, watchlist, liveActivity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .downloads: "Downloads"
        case .downloadOnly: "Download only"
        case .watchlist: "Watchlist"
        case .liveActivity: "Live Activity"
        }
    }

    var detail: String {
        switch self {
        case .downloads: "A file finished downloading to this iPhone, or failed."
        case .downloadOnly: "A \"Download only\" item is on this iPhone and removed from its service, or stopped on an error."
        case .watchlist: "A series on your watchlist has new episodes, or a movie is out digitally. Checked when Dove opens."
        case .liveActivity: "Download progress on the Lock Screen and in the Dynamic Island."
        }
    }

    var symbol: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .downloadOnly: "arrow.down.to.line.circle"
        case .watchlist: "bookmark"
        case .liveActivity: "platter.filled.bottom.iphone"
        }
    }

    /// Live Activities are not notifications: iOS does not ask for them.
    var needsPermission: Bool { self != .liveActivity }

    private var key: String { "notify.\(rawValue)" }

    /// On unless the user turned it off.
    var isOn: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum LocalNotifications {
    /// Asks iOS once, the first time a kind that is on has something to say.
    static func askIfNeeded(for kind: NotificationKind) {
        guard kind.isOn, kind.needsPermission else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Posts at once, unless the user turned the kind off (iOS drops it anyway without permission).
    static func post(_ kind: NotificationKind, id: String, title: String, body: String, thread: String) {
        guard kind.isOn else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Settings › Notifications: whether iOS lets Dove notify, and which kinds Dove sends.
struct NotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus?
    /// Mirrors `NotificationKind.isOn` so the toggles redraw.
    @State private var enabled: [NotificationKind: Bool] = [:]

    var body: some View {
        Form {
            Section {
                switch status {
                case .notDetermined:
                    Button("Allow notifications", systemImage: "bell.badge") { request() }
                case .denied:
                    LabeledContent("iOS", value: "Off")
                    Button("Open iPhone Settings", systemImage: "gear") { openSystemSettings() }
                case nil:
                    ProgressView()
                default:
                    LabeledContent("iOS", value: "Allowed")
                    Button("Notification style in iPhone Settings", systemImage: "gear") { openSystemSettings() }
                }
            } footer: {
                Text(statusFooter)
            }

            Section {
                ForEach(NotificationKind.allCases) { kind in
                    Toggle(isOn: binding(kind)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kind.title)
                                Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: kind.symbol)
                        }
                    }
                }
            } header: {
                Text("Dove tells you about")
            } footer: {
                Text("Dove has no server, so nothing is pushed: notifications come from Dove itself, when iOS wakes it for a finished download or when you open it. Saved on this iPhone.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) { await refresh() }
        .onAppear {
            for kind in NotificationKind.allCases { enabled[kind] = kind.isOn }
        }
    }

    private var statusFooter: String {
        switch status {
        case .notDetermined: "iOS asks once. Dove also asks the first time something on the list below happens."
        case .denied: "iOS blocks Dove's notifications. Turn them on in iPhone Settings › Notifications › Dove."
        default: "Banners, sounds and Lock Screen are set in iPhone Settings."
        }
    }

    private func binding(_ kind: NotificationKind) -> Binding<Bool> {
        Binding(
            get: { enabled[kind] ?? kind.isOn },
            set: { value in
                kind.isOn = value
                enabled[kind] = value
                if value { LocalNotifications.askIfNeeded(for: kind) }
            }
        )
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func request() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refresh()
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
