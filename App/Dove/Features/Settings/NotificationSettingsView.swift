import DoveAppCore
import SwiftUI
import UIKit
import UserNotifications

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
