import DoveAppCore
import SwiftUI
import UserNotifications

/// Settings › Notifications: whether the system lets Dove notify, and which kinds Dove sends.
struct NotificationSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status: UNAuthorizationStatus?
    /// Why the system refused to ask (a build it does not know, e.g. not registered with Launch Services).
    @State private var requestError: String?
    /// Mirrors `NotificationKind.isOn` so the toggles redraw.
    @State private var enabled: [NotificationKind: Bool] = [:]

    var body: some View {
        Form {
            Section {
                switch status {
                case .notDetermined:
                    Button("Allow notifications", systemImage: "bell.badge") { request() }
                case .denied:
                    LabeledContent(SystemSettings.systemName, value: "Off")
                    Button("Open \(SystemSettings.appName)", systemImage: "gear") { SystemSettings.openNotifications() }
                case nil:
                    ProgressView()
                default:
                    LabeledContent(SystemSettings.systemName, value: "Allowed")
                    Button("Notification style in \(SystemSettings.appName)", systemImage: "gear") { SystemSettings.openNotifications() }
                }
                if let requestError {
                    SettingsStatusView(status: .failure(requestError))
                }
            } footer: {
                Text(statusFooter)
            }

            Section {
                ForEach(NotificationKind.shown) { kind in
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
        case .notDetermined: "\(SystemSettings.systemName) asks once. Dove also asks the first time something on the list below happens."
        case .denied: "\(SystemSettings.systemName) blocks Dove's notifications. Turn them on in \(SystemSettings.appName) › Notifications › Dove."
        default: "Banners, sounds and Lock Screen are set in \(SystemSettings.appName)."
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
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                requestError = nil
            } catch {
                requestError = error.localizedDescription
            }
            await refresh()
        }
    }
}

private extension NotificationKind {
    /// The Mac has no Live Activity.
    static var shown: [NotificationKind] {
        #if os(iOS)
        allCases
        #else
        allCases.filter { $0 != .liveActivity }
        #endif
    }
}
