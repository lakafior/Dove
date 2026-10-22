import DoveAppCore
import DoveKit
import SwiftUI

/// Settings › Plugins: repositories added by URL, their plugins, installed ones with updates.
struct PluginsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var addingRepository = false
    @State private var pending: PluginsModel.Pending?
    @State private var error: String?
    @State private var isChecking = false

    private var plugins: PluginsModel { model.plugins }

    var body: some View {
        Form {
            Section {
                if plugins.installed.isEmpty {
                    Text("No plugins yet. Add a repository, then install its plugins.").foregroundStyle(.secondary)
                }
                ForEach(plugins.installed) { plugin in
                    NavigationLink {
                        PluginDetailView(pluginID: plugin.id)
                    } label: {
                        PluginRow(plugin: plugin, update: plugins.update(for: plugin), hasScript: plugins.scripts[plugin.id] != nil)
                    }
                }
            } header: {
                Text("Installed")
            } footer: {
                Text("Plugins run on this iPhone, each call in a fresh sandbox that reaches only the hosts it declares. Dove installs and updates them only when you tap.")
            }

            ForEach(plugins.repositories, id: \.self) { url in
                Section {
                    let available = plugins.available(in: url)
                    if let message = plugins.indexErrors[url] {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    } else if available.isEmpty {
                        Text("Everything here is installed.").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(available) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                Text([entry.version, entry.summary].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if plugins.busy.contains(entry.id) {
                                ProgressView()
                            } else {
                                Button("Install") { prepare(entry, from: url) }.buttonStyle(.bordered)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(plugins.indexes[url]?.name ?? url.host() ?? url.absoluteString)
                        Spacer()
                        Button("Remove", role: .destructive) { plugins.removeRepository(url) }
                            .font(.caption)
                            .textCase(nil)
                    }
                } footer: {
                    Text(url.absoluteString).font(.caption2)
                }
            }

            Section {
                Button("Add repository", systemImage: "plus") { addingRepository = true }
                Button {
                    isChecking = true
                    Task {
                        await plugins.refreshIndexes(force: true)
                        isChecking = false
                    }
                } label: {
                    HStack {
                        Label("Check for updates", systemImage: "arrow.clockwise")
                        if isChecking { Spacer(); ProgressView() }
                    }
                }
                .disabled(plugins.repositories.isEmpty || isChecking)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            } footer: {
                Text("A repository is the address of an index.json listing plugins (for example on GitHub Pages). Dove ships none.")
            }
        }
        .navigationTitle("Plugins")
        .navigationBarTitleDisplayMode(.inline)
        .task { await plugins.refreshIndexes() }
        .sheet(isPresented: $addingRepository) { AddRepositorySheet() }
        .sheet(item: $pending) { pending in
            PluginConsentSheet(pending: pending) { self.pending = nil }
        }
    }

    private func prepare(_ entry: PluginRepositoryIndex.Entry, from url: URL) {
        error = nil
        Task {
            do {
                pending = try await plugins.prepare(entry, from: url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct PluginRow: View {
    let plugin: InstalledPlugin
    let update: PluginRepositoryIndex.Entry?
    let hasScript: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(plugin.manifest.name)
                if !plugin.enabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 6) {
                Text(plugin.entry.version)
                Text(plugin.manifest.capabilities.map(\.rawValue).joined(separator: ", "))
                if let update { Text("Update \(update.version)").foregroundStyle(.blue) }
                if !hasScript { Text("Downloading…").foregroundStyle(.orange) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// What a plugin may reach and use, before it is kept (also for an update that adds hosts).
struct PluginConsentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pending: PluginsModel.Pending
    let done: () -> Void
    @State private var error: String?

    private var manifest: PluginManifest { pending.plugin.manifest }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Version", value: manifest.version)
                    LabeledContent("Does", value: manifest.capabilities.map(\.rawValue).joined(separator: ", "))
                    if !manifest.categories.isEmpty {
                        LabeledContent("In", value: manifest.categories.map(\.displayName).joined(separator: ", "))
                    }
                } header: {
                    Text(manifest.name)
                }
                Section {
                    ForEach(manifest.hosts, id: \.self) { host in
                        Label(host, systemImage: pending.newHosts.contains(host) ? "network.badge.shield.half.filled" : "network")
                    }
                } header: {
                    Text("May connect to")
                } footer: {
                    Text("The plugin reaches nothing else. {Names} are filled from its settings, which only this plugin gets.")
                }
                if !manifest.settings.isEmpty {
                    Section("Asks for") {
                        ForEach(manifest.settings) { setting in
                            Text(setting.title + (setting.type == .secret ? " (kept in the Keychain)" : ""))
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(pending.newHosts.count == manifest.hosts.count ? "Install plugin" : "Update plugin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Allow") {
                        do {
                            try model.plugins.accept(pending)
                            done()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

private struct AddRepositorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…/index.json", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Dove reads the list of plugins from it; nothing is installed yet.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Add repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding { ProgressView() } else {
                        Button("Add") {
                            isAdding = true
                            Task {
                                do {
                                    try await model.plugins.addRepository(address)
                                    dismiss()
                                } catch {
                                    self.error = error.localizedDescription
                                }
                                isAdding = false
                            }
                        }
                        .disabled(address.isEmpty)
                    }
                }
            }
        }
    }
}

/// One installed plugin: its settings, what it reaches, update and removal.
struct PluginDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pluginID: String
    @State private var pending: PluginsModel.Pending?
    @State private var error: String?

    private var plugin: InstalledPlugin? { model.plugins.installed.first { $0.id == pluginID } }

    var body: some View {
        Form {
            if let plugin {
                Section {
                    Toggle("On", isOn: Binding(
                        get: { plugin.enabled },
                        set: { model.plugins.setEnabled(plugin.id, $0) }
                    ))
                    LabeledContent("Version", value: plugin.entry.version)
                    LabeledContent("Does", value: plugin.manifest.capabilities.map(\.rawValue).joined(separator: ", "))
                    if !plugin.manifest.categories.isEmpty {
                        LabeledContent("In", value: plugin.manifest.categories.map(\.displayName).joined(separator: ", "))
                    }
                }
                if !plugin.manifest.settings.isEmpty {
                    Section("Settings") {
                        ForEach(plugin.manifest.settings) { setting in
                            PluginSettingField(pluginID: plugin.id, setting: setting)
                        }
                    }
                }
                Section("May connect to") {
                    ForEach(plugin.manifest.hosts, id: \.self) { Text($0) }
                }
                Section {
                    if let update = model.plugins.update(for: plugin) {
                        Button("Update to \(update.version)") {
                            Task {
                                do {
                                    pending = try await model.plugins.prepare(update, from: plugin.repository)
                                } catch {
                                    self.error = error.localizedDescription
                                }
                            }
                        }
                    }
                    Button("Remove plugin", role: .destructive) {
                        model.plugins.uninstall(plugin.id)
                        dismiss()
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                } footer: {
                    Text(plugin.repository.absoluteString).font(.caption2)
                }
            }
        }
        .navigationTitle(plugin?.manifest.name ?? "Plugin")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pending) { pending in
            PluginConsentSheet(pending: pending) { self.pending = nil }
        }
    }
}

private struct PluginSettingField: View {
    @Environment(AppModel.self) private var model
    let pluginID: String
    let setting: PluginManifest.Setting
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch setting.type {
            case .toggle:
                Toggle(setting.title, isOn: Binding(
                    get: {
                        if case .toggle(let on) = model.plugins.value(pluginID, setting.key) ?? setting.default { return on }
                        return false
                    },
                    set: { model.plugins.setValue(.toggle($0), for: setting.key, of: pluginID) }
                ))
            case .text, .secret:
                Group {
                    if setting.type == .secret {
                        SecureField(setting.title + (setting.required ? "" : " (optional)"), text: $text)
                    } else {
                        TextField(setting.title + (setting.required ? "" : " (optional)"), text: $text)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(save)
                .onChange(of: text) { save() }
            }
            if let help = setting.help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear {
            if let value = model.plugins.value(pluginID, setting.key) { text = value.text }
        }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        model.plugins.setValue(trimmed.isEmpty ? nil : .text(trimmed), for: setting.key, of: pluginID)
    }
}
