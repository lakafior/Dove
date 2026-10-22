import SwiftUI

/// The one switch for adult content: Library, Search, Downloads and plugins all follow it.
struct AdultContentSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Show adult content", isOn: $model.showAdult)
            } footer: {
                Text("Off hides adult items in the Library and the Files app, the Adult search category, adult plugins and the Adult row in Save to. Synced to your other devices. Library › ⋯ has the same switch.")
            }
        }
        .navigationTitle("Adult content")
        .navigationBarTitleDisplayMode(.inline)
    }
}
