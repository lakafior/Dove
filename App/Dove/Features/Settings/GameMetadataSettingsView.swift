import DoveKit
import SwiftUI

/// Where game covers and titles come from: Wikidata (free, no covers) and IGDB through the user's own Twitch app,
/// with the steps to make one.
struct GameMetadataSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var status: SettingsStatus?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                LabeledContent("IGDB", value: model.igdbCredentials == nil ? "Needs a Twitch app" : "Connected")
                LabeledContent("Wikidata", value: "Free")
            } header: {
                Text("Sources")
            } footer: {
                Text("Searched at once for Games. IGDB has covers, platforms and other names for retro and new games alike; Wikidata works without setup but has no covers.")
            }

            Section {
                let plugins = model.gameMetadata.catalogs
                if plugins.isEmpty {
                    Text("None. Plugins can add more sources: Settings › Plugins.").foregroundStyle(.secondary)
                }
                ForEach(plugins.map(\.name), id: \.self) { name in
                    Text(name)
                }
            } header: {
                Text("From plugins")
            } footer: {
                Text("Asked with IGDB and Wikidata. The same game from several sources is one row: IGDB's, with a plugin's cover when IGDB has none.")
            }

            Section {
                step(1, "Sign in at dev.twitch.tv with a Twitch account (a free one is fine) and turn on two-factor authentication in Twitch › Settings › Security.")
                step(2, "Open Your Console › Applications › Register Your Application.")
                step(3, "Name: anything (Twitch wants it unique, e.g. \u{201C}Dove\u{201D} plus your name). OAuth Redirect URL: http://localhost. Category: Application Integration. Client Type: Confidential.")
                step(4, "Create it, then tap Manage: copy the Client ID, press New Secret and copy the Client Secret.")
                step(5, "Paste both below and tap Save and test.")
                if let console = URL(string: "https://dev.twitch.tv/console/apps") {
                    Link(destination: console) { Label("Open the Twitch developer console", systemImage: "safari") }
                }
            } header: {
                Text("IGDB: make a Twitch app")
            } footer: {
                Text("IGDB belongs to Twitch and is free for personal, non-commercial use. The app and its secret are yours: Dove keeps them in your iCloud Keychain and sends them only to Twitch and IGDB.")
            }

            Section {
                TextField("Client ID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Client Secret", text: $clientSecret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(save)
                Button(action: save) {
                    HStack {
                        Text("Save and test")
                        if saving { Spacer(); ProgressView() }
                    }
                }
                .disabled(saving)
                if let status { SettingsStatusView(status: status) }
            } header: {
                Text("IGDB")
            } footer: {
                Text("Clear both fields and save to remove them.")
            }
        }
        .navigationTitle("Game metadata")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            clientID = model.igdbClientID
            clientSecret = model.igdbClientSecret
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).font(.subheadline)
        }
    }

    private func save() {
        saving = true
        status = nil
        Task {
            do {
                try await model.saveIGDB(clientID: clientID, clientSecret: clientSecret)
                status = clientID.isEmpty && clientSecret.isEmpty ? .note("Removed.") : .success("IGDB works.")
            } catch {
                status = SettingsStatus(error)
            }
            saving = false
        }
    }
}
