import DoveKit
import SwiftUI

/// One row per service or feature, each saying whether it is set up; the fields live one tap deeper, so no
/// section starts open and every service works the same way.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach([BackendID.realDebrid, .torBox, .offcloud, .debridLink, .premiumize, .allDebrid], id: \.self) { backend in
                        NavigationLink {
                            DebridKeyView(backend: backend)
                        } label: {
                            SettingsRow(backend.displayName, symbol: backend.settingsSymbol, color: backend.settingsColor,
                                        value: serviceValue(backend), light: serviceLight(backend))
                        }
                    }
                    NavigationLink {
                        DebridPriorityView()
                    } label: {
                        SettingsRow("Priority", symbol: "arrow.up.arrow.down", color: .gray,
                                    value: priorityOrder.map(\.displayName).joined(separator: " → "))
                    }
                    if model.canChoosePrivateTrackers {
                        Picker(selection: privateTrackers) {
                            ForEach([PrivateTrackerTarget.debridLink, .torBox, .both]) { Text($0.name).tag($0) }
                        } label: {
                            Label {
                                Text("Private trackers")
                            } icon: {
                                SettingsIcon(symbol: "lock.fill", color: .red)
                            }
                        }
                    }
                } header: {
                    Text("Debrid")
                } footer: {
                    Text("Torrents and links go to the first service in Priority. If it fails, Dove tries the next one. \(privateTrackersFooter)")
                }

                Section {
                    NavigationLink {
                        NzbdavSettingsView()
                    } label: {
                        SettingsRow("nzbdav", symbol: BackendID.nzbdav.settingsSymbol, color: BackendID.nzbdav.settingsColor,
                                    value: serviceValue(.nzbdav), light: serviceLight(.nzbdav))
                    }
                    DebridUsenetToggle(backend: .torBox)
                    DebridUsenetToggle(backend: .offcloud)
                    DebridUsenetToggle(backend: .premiumize)
                    NavigationLink {
                        UsenetPriorityView()
                    } label: {
                        SettingsRow("Priority", symbol: "arrow.up.arrow.down", color: .gray,
                                    value: model.nzbBackends.map(\.id.displayName).joined(separator: " → "))
                    }
                } header: {
                    Text("Usenet")
                } footer: {
                    Text("NZBs go to the first service in Priority. If it fails, Dove tries the next one. TorBox Usenet needs the Pro plan.")
                }

                Section {
                    NavigationLink {
                        AddonsView()
                    } label: {
                        SettingsRow("Stremio addons", symbol: "puzzlepiece.extension.fill", color: .indigo,
                                    value: "\(model.addonEntries.count)")
                    }
                    NavigationLink {
                        NewznabIndexersView()
                    } label: {
                        SettingsRow("Indexers", symbol: "list.bullet.rectangle.fill", color: .teal,
                                    value: "\(model.newznabIndexers.filter(\.enabled).count)")
                    }
                    NavigationLink {
                        TMDBSettingsView()
                    } label: {
                        SettingsRow("TMDB", symbol: "film.stack.fill", color: .cyan,
                                    value: model.addonSet.tmdb != nil ? "Connected" : "Not set up")
                    }
                } header: {
                    Text("Search and metadata")
                } footer: {
                    Text("Addons give sources (and titles, without TMDB). Indexers are searched from your phone and power Search › Other. TMDB gives search, posters and episodes.")
                }

                Section("This iPhone") {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        SettingsRow("Notifications", symbol: "bell.badge.fill", color: .red)
                    }
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        SettingsRow("Playback", symbol: "play.fill", color: .pink, value: model.playback.player.displayName)
                    }
                    NavigationLink {
                        BookSettingsView()
                    } label: {
                        SettingsRow("Books", symbol: "book.fill", color: .orange,
                                    value: model.readIn?.displayName ?? "Ask")
                    }
                    NavigationLink {
                        FilesLocationView()
                    } label: {
                        SettingsRow("Files app", symbol: "folder.fill", color: .blue)
                    }
                    NavigationLink {
                        StorageView()
                    } label: {
                        SettingsRow("Storage", symbol: "internaldrive.fill", color: .gray)
                    }
                }

                Section {
                    NavigationLink {
                        SettingsTransferView()
                    } label: {
                        SettingsRow("Export & import", symbol: "arrow.up.arrow.down", color: .teal)
                    }
                } footer: {
                    Text("Settings as a file, for a device iCloud Keychain does not reach.")
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
        }
    }

    /// "213 days left" (debrids), "Online"/"Offline" from the last library refresh, or "Not set up".
    private func serviceValue(_ backend: BackendID) -> String {
        guard model.isConfigured(backend) else { return "Not set up" }
        if case .offline = model.services.health(of: backend) { return "Offline" }
        return model.services.accountSummary(backend) ?? "Connected"
    }

    private func serviceLight(_ backend: BackendID) -> Color? {
        model.isConfigured(backend) ? model.services.light(backend) : nil
    }

    /// Automatic sends them to Debrid-Link, so the picker shows it as that.
    private var privateTrackers: Binding<PrivateTrackerTarget> {
        Binding {
            model.privateTrackers == .automatic ? .debridLink : model.privateTrackers
        } set: {
            model.privateTrackers = $0
        }
    }

    private var privateTrackersFooter: String {
        let services = model.privateTrackerServices
        guard !services.isEmpty else {
            return "Torrents from private trackers need a service that seeds: Debrid-Link, or TorBox on a paid plan."
        }
        var text = "Torrents from private trackers go only to \(services.map(\.displayName).joined(separator: " or ")), which seed\(services.count == 1 ? "s" : "")."
        if services.contains(.torBox), let plan = model.torBoxPlan.plan, let time = plan.seedingTimeText {
            text += " TorBox \(plan.name) seeds for \(time)"
            text += plan == .essential ? ": most private trackers ask for 72 hours or more." : "."
        }
        return text
    }

    /// The summary lists only services with a key; the full order (with "No key" rows) is one tap away.
    private var priorityOrder: [BackendID] {
        let configured = model.debridOrder.filter(model.isConfigured)
        return configured.isEmpty ? model.debridOrder : configured
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// A Settings-style row: a coloured icon, the name, and its state on the right.
struct SettingsRow: View {
    let title: String
    let symbol: String
    let color: Color
    var value: String?
    /// A status light before the value (services).
    var light: Color?

    init(_ title: String, symbol: String, color: Color, value: String? = nil, light: Color? = nil) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.value = value
        self.light = light
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let light { StatusLight(color: light) }
                if let value { Text(value).lineLimit(1) }
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                SettingsIcon(symbol: symbol, color: color)
            }
        }
    }
}

/// The white symbol on a coloured rounded square that leads every Settings row.
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7))
    }
}

extension BackendID {
    var settingsSymbol: String {
        switch self {
        case .realDebrid: "bolt.fill"
        case .torBox: "shippingbox.fill"
        case .offcloud: "cloud.fill"
        case .debridLink: "link"
        case .premiumize: "crown.fill"
        case .allDebrid: "a.circle.fill"
        case .nzbdav: "server.rack"
        }
    }

    var settingsColor: Color {
        switch self {
        case .realDebrid: .green
        case .torBox: .purple
        case .offcloud: .blue
        case .debridLink: .teal
        case .premiumize: .red
        case .allDebrid: .yellow
        case .nzbdav: .orange
        }
    }

    /// Where the user finds the key.
    var keyHelp: String {
        switch self {
        case .realDebrid: "real-debrid.com › My account › API token (real-debrid.com/apitoken)."
        case .torBox: "torbox.app › Settings › API key."
        case .offcloud: "offcloud.com › Account › API key."
        case .debridLink: "debrid-link.com › My account › API key. Debrid-Link seeds, so torrents from private trackers can go here."
        case .premiumize: "premiumize.me › Account › API key. Every plan includes Usenet."
        case .allDebrid: "alldebrid.com › Account › API keys (alldebrid.com/apikeys). A new key may need confirming from the e-mail AllDebrid sends."
        case .nzbdav: ""
        }
    }
}

/// One debrid service: its key, saved to the Keychain and tested.
private struct DebridKeyView: View {
    @Environment(AppModel.self) private var model
    let backend: BackendID
    @State private var value = ""
    @State private var status: String?
    @State private var isTesting = false

    private var key: CredentialKey {
        switch backend {
        case .realDebrid: .realDebridAPIKey
        case .torBox: .torBoxAPIKey
        case .offcloud: .offcloudAPIKey
        case .debridLink: .debridLinkAPIKey
        case .premiumize: .premiumizeAPIKey
        case .allDebrid: .allDebridAPIKey
        case .nzbdav: .nzbdavAPIKey
        }
    }

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(saveAndTest)
            } header: {
                Text("API key")
            } footer: {
                Text(backend.keyHelp)
            }
            Section {
                Button(action: saveAndTest) {
                    HStack {
                        Text("Save and test connection")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting)
                if let status { Text(status).font(.footnote) }
            }
            if backend == .torBox, model.isConfigured(.torBox) {
                Section {
                    Picker("Plan", selection: torBoxPlan) {
                        Text(model.torBoxPlan.detected.map { "Automatic (\($0.name))" } ?? "Automatic").tag(TorBoxPlan?.none)
                        ForEach(TorBoxPlan.ordered) { Text($0.name).tag(Optional($0)) }
                    }
                } header: {
                    Text("Plan")
                } footer: {
                    Text(torBoxPlanFooter)
                }
            }
            if model.isConfigured(backend) {
                Section {
                    Button("Remove key", role: .destructive) {
                        value = ""
                        saveAndTest()
                    }
                }
            }
        }
        .navigationTitle(backend.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { value = (try? model.keychain.get(key)) ?? "" }
    }

    private var torBoxPlan: Binding<TorBoxPlan?> {
        Binding { model.torBoxPlan.chosen } set: { model.torBoxPlan.chosen = $0 }
    }

    private var torBoxPlanFooter: String {
        let source = model.torBoxPlan.detected == nil
            ? "TorBox has not reported the plan yet; pick it here."
            : "Read from your TorBox account; pick one only if it is wrong."
        guard let plan = model.torBoxPlan.plan else { return source }
        return "\(source) \(plan.name): \(plan.features)."
    }

    private func saveAndTest() {
        do {
            try model.keychain.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: key)
        } catch {
            status = "Keychain error: \(error)"
            return
        }
        model.reloadBackends()
        guard let service = model.backend(backend) else {
            status = "Key removed."
            return
        }
        status = nil
        isTesting = true
        Task {
            do {
                try await service.validateCredentials()
                status = "✅ Connected to \(backend.displayName)."
                await model.refreshAccounts(force: true)
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
            isTesting = false
        }
    }
}

/// TMDB key: validated against TMDB before it is saved.
private struct TMDBSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var value = ""
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                SecureField("API key or read access token", text: $value)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(save)
            } header: {
                Text("Key")
            } footer: {
                Text("Get a free key at themoviedb.org › Settings › API (the API key or the read access token).")
            }
            Section {
                Button(action: save) {
                    HStack {
                        Text("Save and test")
                        if isSaving { Spacer(); ProgressView() }
                    }
                }
                .disabled(isSaving)
                if let status { Text(status).font(.footnote) }
            } footer: {
                Text("With a key, search, posters, seasons, episodes and the home screen's trending titles come from TMDB first; your addons answer when TMDB cannot.")
            }
        }
        .navigationTitle("TMDB")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { value = model.tmdbKey }
    }

    private func save() {
        isSaving = true
        status = nil
        Task {
            do {
                try await model.saveTMDBKey(value)
                status = value.isEmpty ? "Key removed." : "✅ TMDB key works."
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
            isSaving = false
        }
    }
}

/// The "Dove" location in the Files app: re-register it when Files shows an error next to it.
private struct FilesLocationView: View {
    @State private var status: String?
    @State private var isResetting = false

    var body: some View {
        Form {
            Section {
                Button {
                    isResetting = true
                    Task {
                        do {
                            try await FilesLocation.reset()
                            status = "Done. Open Files, tap Dove and turn it on."
                        } catch {
                            status = error.localizedDescription
                        }
                        isResetting = false
                    }
                } label: {
                    HStack {
                        Text("Reset Files location")
                        if isResetting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isResetting)
                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Your services appear in Files under Locations › Dove. If Files shows an error there, reset it: Files forgets what it knew and lists everything again.")
            }
        }
        .navigationTitle("Files app")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What Dove keeps on this phone besides downloads: artwork and the last library list.
private struct StorageView: View {
    @State private var imageBytes: Int64?

    var body: some View {
        Form {
            Section {
                LabeledContent("Posters and covers", value: imageBytes.map { $0.formatted(.byteCount(style: .file)) } ?? "…")
                Button("Clear artwork", role: .destructive) {
                    Task {
                        await ImageCache.shared.removeAll()
                        DecodedImages.shared.removeAll()
                        imageBytes = await ImageCache.shared.size()
                    }
                }
                .disabled(imageBytes == 0)
            } footer: {
                Text("Artwork is kept so the library does not download it again on every launch. iOS may also clear it when space runs low; Dove then fetches it again as needed. Downloads are in the Downloads tab.")
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { imageBytes = await ImageCache.shared.size() }
    }
}

/// A small coloured dot: green online, orange worth a look, red offline, grey not known yet.
struct StatusLight: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 2)
            .accessibilityHidden(true)
    }
}

extension ServiceStatusModel {
    func light(_ backend: BackendID) -> Color {
        switch health(of: backend) {
        case .offline: .red
        case .unknown: needsAttention(backend) ? .orange : .gray
        case .online: needsAttention(backend) ? .orange : .green
        }
    }
}

extension TorBoxPlan {
    /// What the plan means for Dove.
    var features: String {
        let seeding = seedingTimeText.map { "seeds finished torrents for \($0), so private trackers can go here" } ?? "no seeding"
        let usenet = includesUsenet ? "Usenet included" : "no Usenet"
        return "\(usenet), \(seeding)"
    }
}
