import DoveKit
import Foundation
import Observation

/// The user's plugin repositories and installed plugins (`docs/plugins.md`): adding repositories, installing,
/// updating (only on a tap), settings, and the plugins other screens call.
@MainActor @Observable
public final class PluginsModel {
    public private(set) var repositories: [URL] = []
    public private(set) var installed: [InstalledPlugin] = []
    public private(set) var settings: [String: [String: SettingValue]] = [:]
    /// The last index each repository answered.
    public private(set) var indexes: [URL: PluginRepositoryIndex] = [:]
    public private(set) var indexErrors: [URL: String] = [:]
    /// Scripts on this device, by plugin id.
    public private(set) var scripts: [String: String] = [:]
    /// Plugins being installed or updated, by id.
    public private(set) var busy: Set<String> = []
    /// Adult plugins show only with the app's adult-content switch.
    public var showAdult = false

    /// Called after anything a plugin call depends on changed (installs, settings, on/off).
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let store: PluginStore
    @ObservationIgnored private let client = PluginRepositoryClient()
    private static let lastCheckKey = "pluginIndexCheck"

    public init(store: PluginStore) {
        self.store = store
        load()
    }

    /// Reads everything again (launch, settings import). Scripts missing here (another device installed them,
    /// or the files were cleared) are downloaded again from their repository, checked against the pinned hash.
    public func load() {
        repositories = store.repositories()
        installed = store.installed()
        settings = store.settings()
        scripts = Dictionary(uniqueKeysWithValues: installed.compactMap { plugin in store.script(for: plugin).map { (plugin.id, $0) } })
        let missing = installed.filter { scripts[$0.id] == nil }
        if !missing.isEmpty {
            Task { for plugin in missing { try? await reinstall(plugin) } }
        }
        onChange?()
    }

    // MARK: - Calls

    /// Enabled plugins with a capability, ready to call; `category` keeps those serving it (or naming none).
    public func calls(_ capability: PluginManifest.Capability, category: SearchCategory? = nil) -> [PluginCall] {
        installed.compactMap { plugin -> PluginCall? in
            guard plugin.enabled, plugin.manifest.can(capability), showAdult || !plugin.manifest.adult,
                  let script = scripts[plugin.id] else { return nil }
            if let category, !plugin.manifest.categories.isEmpty, !plugin.manifest.categories.contains(category) { return nil }
            return PluginCall(manifest: plugin.manifest, script: script, settings: settings[plugin.id] ?? [:])
        }
    }

    /// Enabled plugins with a search page (`browse`) for a category. Only plugins that cannot search in the app:
    /// the browser is for sites whose results a scripted request cannot list (captchas, bot checks); a plugin
    /// with `search` shows its rows on the Plugins tab instead.
    public func browsers(for category: SearchCategory) -> [PluginCall] {
        calls(.resolve, category: category).filter { $0.manifest.browse != nil && !$0.manifest.can(.search) }
    }

    /// The plugin that knows a file page's address, and the id it reads from it.
    public func link(for url: URL) -> (call: PluginCall, id: String)? {
        for call in calls(.resolve) {
            if let id = call.linkID(in: url) { return (call, id) }
        }
        return nil
    }

    public func manifests() -> [PluginManifest] { installed.map(\.manifest) }

    // MARK: - Repositories

    public func addRepository(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: full), url.scheme?.lowercased() == "https", url.host() != nil else {
            throw PluginError("Enter the repository's https address (its index.json).")
        }
        guard !repositories.contains(url) else { return }
        indexes[url] = try await client.index(at: url)
        indexErrors[url] = nil
        repositories.append(url)
        try store.saveRepositories(repositories)
    }

    /// Removes the repository; its installed plugins stay (they keep working, without updates).
    public func removeRepository(_ url: URL) {
        repositories.removeAll { $0 == url }
        indexes[url] = nil
        indexErrors[url] = nil
        try? store.saveRepositories(repositories)
    }

    /// Asks every repository again: at launch at most once a day, or now (`force`).
    public func refreshIndexes(force: Bool = false) async {
        let defaults = DoveStorage.defaults
        if !force, let last = defaults.object(forKey: Self.lastCheckKey) as? Date, Date().timeIntervalSince(last) < 24 * 3600,
           !indexes.isEmpty || repositories.isEmpty {
            return
        }
        for url in repositories {
            do {
                indexes[url] = try await client.index(at: url)
                indexErrors[url] = nil
            } catch {
                indexErrors[url] = error.localizedDescription
            }
        }
        defaults.set(Date(), forKey: Self.lastCheckKey)
    }

    /// Plugins of a repository this build can run and the user may see, not installed yet.
    public func available(in url: URL) -> [PluginRepositoryIndex.Entry] {
        (indexes[url]?.plugins ?? []).filter { entry in
            entry.isSupported && (showAdult || entry.adult != true) && !installed.contains { $0.id == entry.id }
        }
    }

    /// A newer version in the plugin's repository, if any.
    public func update(for plugin: InstalledPlugin) -> PluginRepositoryIndex.Entry? {
        guard let entry = indexes[plugin.repository]?.plugins.first(where: { $0.id == plugin.id }),
              entry.isSupported, entry.isNewer(than: plugin.entry) else { return nil }
        return entry
    }

    public var updatesAvailable: Int { installed.filter { update(for: $0) != nil }.count }

    // MARK: - Installing

    /// A downloaded, verified plugin the user has not accepted yet.
    public struct Pending: Identifiable {
        public let plugin: InstalledPlugin
        public let script: String
        /// Hosts the installed version could not reach (all of them for a new plugin).
        public let newHosts: [String]
        public var id: String { plugin.id }
    }

    /// Downloads and checks a plugin (or a newer version); nothing is kept until `accept`.
    public func prepare(_ entry: PluginRepositoryIndex.Entry, from repository: URL) async throws -> Pending {
        busy.insert(entry.id)
        defer { busy.remove(entry.id) }
        let (plugin, script) = try await client.install(entry, from: repository)
        let known = Set(installed.first { $0.id == plugin.id }?.manifest.hosts ?? [])
        return Pending(plugin: plugin, script: script, newHosts: plugin.manifest.hosts.filter { !known.contains($0) })
    }

    /// Keeps a prepared plugin: the user saw its hosts.
    public func accept(_ pending: Pending) throws {
        store.removeScripts(of: pending.plugin.id)
        try store.saveScript(pending.script, for: pending.plugin.entry)
        var next = pending.plugin
        next.enabled = installed.first { $0.id == next.id }?.enabled ?? true
        var list = installed.filter { $0.id != next.id }
        list.append(next)
        try store.saveInstalled(list)
        installed = list
        scripts[next.id] = pending.script
        onChange?()
    }

    /// The same pinned version again (a device without the script file).
    private func reinstall(_ plugin: InstalledPlugin) async throws {
        let (fresh, script) = try await client.install(plugin.entry, from: plugin.repository)
        try store.saveScript(script, for: fresh.entry)
        scripts[plugin.id] = script
        onChange?()
    }

    public func uninstall(_ id: String) {
        installed.removeAll { $0.id == id }
        settings[id] = nil
        scripts[id] = nil
        store.removeScripts(of: id)
        try? store.saveInstalled(installed)
        try? store.saveSettings(settings)
        onChange?()
    }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled = enabled
        try? store.saveInstalled(installed)
        onChange?()
    }

    public func value(_ id: String, _ key: String) -> SettingValue? {
        settings[id]?[key]
    }

    public func setValue(_ value: SettingValue?, for key: String, of id: String) {
        var values = settings[id] ?? [:]
        values[key] = value
        settings[id] = values.isEmpty ? nil : values
        try? store.saveSettings(settings)
        onChange?()
    }
}
