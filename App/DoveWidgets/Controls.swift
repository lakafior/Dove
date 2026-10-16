import AppIntents
import SwiftUI
import WidgetKit

// Control Center, Lock Screen and Action button controls (iOS 18): one tap to run what Dove already offers as
// App Intents. They draw nothing from the snapshot.

@available(iOS 18.0, *)
struct ContinueListeningControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "DoveContinueListening") {
            ControlWidgetButton(action: ContinueAudiobookIntent()) {
                Label("Continue Listening", systemImage: "headphones")
            }
        }
        .displayName("Continue Listening")
        .description("Plays the audiobook you listened to last, from where you left it.")
    }
}

@available(iOS 18.0, *)
struct AddFromClipboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "DoveAddFromClipboard") {
            ControlWidgetButton(action: AddFromClipboardIntent()) {
                Label("Add to Dove", systemImage: "doc.on.clipboard")
            }
        }
        .displayName("Add from Clipboard")
        .description("Opens Dove with the magnets and links on the clipboard.")
    }
}
