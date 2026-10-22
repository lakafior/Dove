import DoveAppCore
import DoveKit
import SwiftUI

/// Whether this device can use iCloud Drive › Dove, and what goes there.
struct ICloudDriveSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("iCloud Drive › Dove", value: model.iCloudState)
            } footer: {
                Text("Files kept in iCloud Drive › Dove reach your iPhone, iPad and Mac, open in Files and Apple Books, and show in the Library as their own place. Without iCloud Drive, every download stays on this iPhone.")
            }
            Section {
                NavigationLink {
                    DownloadSettingsView()
                } label: {
                    Text("Choose what goes there")
                }
            } footer: {
                Text("Save to decides, per kind, where downloads go.")
            }
        }
        .navigationTitle("iCloud Drive")
        .navigationBarTitleDisplayMode(.inline)
    }
}

