import DoveKit
import Foundation
import Observation

/// The Mac app's update check (iOS updates come through AltStore). It only tells: the user downloads the DMG.
@MainActor
@Observable
public final class UpdateModel {
    public private(set) var available: AvailableUpdate?
    public private(set) var isChecking = false
    public private(set) var lastError: String?
    public private(set) var isUpToDate = false

    private let checker: UpdateChecker
    private let defaults: UserDefaults
    private let now: () -> Date
    private let currentVersion: AppVersion
    private let platform: any AppPlatform
    private let lastCheckKey = "updateLastCheck"
    private let skippedTagKey = "updateSkippedTag"

    public init(platform: any AppPlatform, transport: any HTTPTransport = URLSession.shared,
                defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
                currentVersion: AppVersion? = nil) {
        self.platform = platform
        checker = UpdateChecker(transport: transport)
        self.defaults = defaults
        self.now = now
        self.currentVersion = currentVersion ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init) ?? AppVersion("0.0.0")!
    }

    /// Quiet: at most once a day, errors ignored, a skipped version stays skipped.
    public func checkAutomatically() async {
        if let last = defaults.object(forKey: lastCheckKey) as? Date, now().timeIntervalSince(last) < 24 * 60 * 60 { return }
        defaults.set(now(), forKey: lastCheckKey)
        do {
            let update = try await checker.latest(newerThan: currentVersion)
            if update?.tag != defaults.string(forKey: skippedTagKey) { available = update }
        } catch { }
    }

    public func checkNow() async {
        isChecking = true
        defer { isChecking = false }
        defaults.set(now(), forKey: lastCheckKey)
        lastError = nil
        isUpToDate = false
        available = nil
        do {
            available = try await checker.latest(newerThan: currentVersion)
            isUpToDate = available == nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func skip(_ update: AvailableUpdate) {
        defaults.set(update.tag, forKey: skippedTagKey)
        available = nil
    }

    public func dismiss() { available = nil }

    public func dismissManualResult() {
        isUpToDate = false
        lastError = nil
    }

    public func dismissAlert() {
        available = nil
        dismissManualResult()
    }

    public func download(_ update: AvailableUpdate) async {
        _ = await platform.open(update.dmgURL ?? update.pageURL)
    }
}
