import DoveKit
import Foundation
import Observation

/// Whether each configured service answers, and how long its premium lasts. "Online" costs nothing: it is what
/// the last library refresh found (every service is listed then). Accounts are one call per debrid at most every
/// six hours, kept between launches.
@MainActor
@Observable
final class ServiceStatusModel {
    enum Health: Equatable {
        case unknown
        case online
        case offline(String)
    }

    private(set) var health: [BackendID: Health] = [:]
    private(set) var accounts: [BackendID: AccountStatus] = [:]

    private struct Saved: Codable {
        var savedAt: Date
        var accounts: [BackendID: AccountStatus]
    }

    private static let savedKey = "serviceAccounts.v1"
    private static let maxAge: TimeInterval = 6 * 60 * 60
    private var savedAt: Date?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            accounts = saved.accounts
            savedAt = saved.savedAt
        }
    }

    func health(of backend: BackendID) -> Health {
        health[backend] ?? .unknown
    }

    /// From a library refresh: services that listed their items are online, the others offline with the reason.
    func record(configured: [BackendID], failed: Set<BackendID>, failures: [String]) {
        var next: [BackendID: Health] = [:]
        for backend in configured {
            if failed.contains(backend) {
                let prefix = "\(backend.displayName): "
                let reason = failures.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
                next[backend] = .offline(reason ?? "No answer")
            } else {
                next[backend] = .online
            }
        }
        health = next
    }

    /// Plans and end dates, unless known from the last few hours (`force` after a key changes).
    func loadAccounts(_ backends: [any LibraryBackend], force: Bool = false) async {
        let reporting = backends.compactMap { $0 as? any AccountReporting }
        let configured = Set(reporting.map(\.id))
        accounts = accounts.filter { configured.contains($0.key) }
        if !force, let savedAt, Date.now.timeIntervalSince(savedAt) < Self.maxAge,
           configured.isSubset(of: Set(accounts.keys)) {
            return
        }
        let loaded = await withTaskGroup(of: (BackendID, AccountStatus?).self) { group in
            for backend in reporting {
                group.addTask { (backend.id, try? await backend.account()) }
            }
            var loaded: [BackendID: AccountStatus] = [:]
            for await (id, account) in group { if let account { loaded[id] = account } }
            return loaded
        }
        // A service that did not answer keeps what it said last time.
        accounts.merge(loaded) { $1 }
        savedAt = .now
        UserDefaults.standard.set(try? JSONEncoder().encode(Saved(savedAt: .now, accounts: accounts)), forKey: Self.savedKey)
    }

    /// "213 days left", "Expires today", "Expired", "Free plan", or nil when nothing is known.
    func accountSummary(_ backend: BackendID) -> String? {
        guard let account = accounts[backend] else { return nil }
        guard account.isPremium else { return "Free plan" }
        guard let days = account.daysLeft() else { return account.plan }
        if let end = account.premiumUntil, end < .now { return "Expired" }
        switch days {
        case 0: return "Expires today"
        case 1: return "1 day left"
        default: return "\(days) days left"
        }
    }

    /// Worth a look: offline, expired, free, or under a week of premium.
    func needsAttention(_ backend: BackendID) -> Bool {
        if case .offline = health(of: backend) { return true }
        guard let account = accounts[backend] else { return false }
        guard account.isPremium else { return true }
        return (account.daysLeft() ?? .max) < 7
    }
}
