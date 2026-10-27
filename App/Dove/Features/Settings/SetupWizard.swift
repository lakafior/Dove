import DoveAppCore
import DoveKit
import SwiftUI

/// A first-run guide that embeds the Settings pages the user chose.
struct SetupWizard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var choices: Set<SetupChoice> = []
    @State private var steps: [SetupStep] = []
    @State private var index = -1

    var body: some View {
        Group {
            if index < 0 {
                welcome
            } else if steps.indices.contains(index), steps[index].page == .done {
                done
            } else if steps.indices.contains(index) {
                settingsStep(steps[index])
            }
        }
        .onAppear { choices = configuredChoices }
    }

    private var welcome: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Bring your own keys. Dove keeps them on your device and in iCloud Keychain.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(groupNames, id: \.self) { group in
                    Section(group) {
                        ForEach(SetupChoice.allCases.filter { $0.group == group }) { choice in
                            Toggle(choice.title, isOn: binding(for: choice))
                        }
                    }
                }
            }
            .navigationTitle("Welcome to Dove")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Button("Skip setup", action: finish)
                    Spacer()
                    Button("Continue", action: begin)
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.bar)
            }
        }
    }

    private var groupNames: [String] {
        ["Services you pay for", "Your own servers", "Search", "Titles and covers", "Places", "Playing and reading"]
    }

    private func binding(for choice: SetupChoice) -> Binding<Bool> {
        Binding(
            get: { choices.contains(choice) },
            set: { if $0 { choices.insert(choice) } else { choices.remove(choice) } }
        )
    }

    private func begin() {
        steps = SetupPlan.steps(for: choices, configured: configuredChoices)
        index = 0
    }

    private func settingsStep(_ step: SetupStep) -> some View {
        NavigationStack {
            step.page.settingsPage.destination
                .formStyle(.grouped)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if step.alreadySet {
                        Label("Already set up", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack {
                        Button("Back") { index -= 1 }
                        Spacer()
                        Text("\(index + 1) of \(max(steps.count - 1, 1))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Skip") { advance() }
                        Button(index == steps.count - 2 ? "Done" : "Next") { advance() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(.bar)
                }
        }
    }

    private var done: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("You’re set", systemImage: "checkmark.circle.fill")
            } description: {
                Text(summary)
            } actions: {
                Button("Done", action: finish)
                    .buttonStyle(.borderedProminent)
            }
            .navigationTitle("Setup")
        }
    }

    private var summary: String {
        let configured = configuredChoices
        let titles = SetupChoice.allCases.filter(configured.contains).map(\.title)
        return titles.isEmpty ? "You can add services and settings any time." : "Configured: " + titles.joined(separator: ", ") + "."
    }

    private var configuredChoices: Set<SetupChoice> {
        var configured = Set(BackendID.services.filter(model.isConfigured).map(SetupChoice.service))
        if model.isConfigured(.nzbdav) { configured.insert(.service(.nzbdav)) }
        if !model.newznabIndexers.isEmpty { configured.insert(.indexers) }
        if !model.addonEntries.isEmpty { configured.insert(.addons) }
        if !model.tmdbKey.isEmpty { configured.insert(.movies) }
        if model.igdbCredentials != nil { configured.insert(.games) }
        let hasBookMetadataPlugin = model.plugins.installed.contains { plugin in
            plugin.enabled && plugin.manifest.can(.metadata)
                && (plugin.manifest.categories.isEmpty
                    || plugin.manifest.categories.contains(.books)
                    || plugin.manifest.categories.contains(.audiobooks))
        }
        if !model.googleBooksKey.isEmpty || !model.hardcoverToken.isEmpty || hasBookMetadataPlugin {
            configured.insert(.books)
        }
        if model.isConfigured(.calibre) { configured.insert(.calibre) }
        if model.isConfigured(.iCloudDrive) { configured.insert(.iCloudDrive) }
        if model.playback.player != .infuse, model.playback.isUsable(model.playback.player) { configured.insert(.player) }
        if !model.kindleAddress.isEmpty || !model.pocketBookAddress.isEmpty || !model.emailAddress.isEmpty {
            configured.insert(.reading)
        }
        return configured
    }

    private func advance() {
        index = min(index + 1, steps.count - 1)
    }

    private func finish() {
        model.setupFinished = true
        dismiss()
    }
}

/// Settings › Set up Dove again on the Mac, where a page cannot present a full-screen flow: it opens the wizard as a sheet.
struct SetupLauncher: View {
    @State private var presented = false

    var body: some View {
        ContentUnavailableView {
            Label("Set up Dove", systemImage: "wand.and.stars")
        } description: {
            Text("Tick what you use and own; setup walks through those settings only.")
        } actions: {
            Button("Start setup") { presented = true }
                .buttonStyle(.borderedProminent)
        }
        .sheet(isPresented: $presented) {
            SetupWizard()
                .frame(minWidth: 640, minHeight: 560)
        }
    }
}

private extension SetupStep.Page {
    var settingsPage: SettingsPage {
        switch self {
        case .service(let backend): .service(backend)
        case .routing: .routing
        case .indexers: .indexers
        case .addons: .addons
        case .movies: .movies
        case .games: .games
        case .books: .books
        case .iCloudDrive: .service(.iCloudDrive)
        case .calibre: .service(.calibre)
        case .saveTo: .saveTo
        case .player: .player
        case .reading: .reading
        case .adult: .adult
        case .done: .transfer
        }
    }
}
