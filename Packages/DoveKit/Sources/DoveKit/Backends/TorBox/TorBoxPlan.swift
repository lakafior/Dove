import Foundation

/// A TorBox subscription. Raw values are `user/me`'s `plan`; what each includes is from torbox.app's pricing page
/// (2026-10): only Pro has Usenet; paid plans seed for 24 hours (Essential), 14 days (Standard) or 30 days (Pro).
public enum TorBoxPlan: Int, Sendable, Codable, CaseIterable, Identifiable {
    case free = 0
    case essential = 1
    case pro = 2
    case standard = 3

    public var id: Int { rawValue }

    /// Cheapest first, for pickers.
    public static let ordered: [TorBoxPlan] = [.free, .essential, .standard, .pro]

    public var name: String {
        switch self {
        case .free: "Free"
        case .essential: "Essential"
        case .standard: "Standard"
        case .pro: "Pro"
        }
    }

    public init?(name: String) {
        guard let plan = Self.allCases.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        self = plan
    }

    /// From the account TorBox reported: no premium is the free plan.
    public init?(account: AccountStatus) {
        if !account.isPremium {
            self = .free
        } else if let name = account.plan, let plan = TorBoxPlan(name: name) {
            self = plan
        } else {
            return nil
        }
    }

    public var includesUsenet: Bool { self == .pro }

    /// How long TorBox keeps seeding a finished torrent; nil when the plan does not seed.
    public var seedingTime: TimeInterval? {
        switch self {
        case .free: nil
        case .essential: 24 * 60 * 60
        case .standard: 14 * 24 * 60 * 60
        case .pro: 30 * 24 * 60 * 60
        }
    }

    /// "24 hours", "14 days", "30 days".
    public var seedingTimeText: String? {
        switch self {
        case .free: nil
        case .essential: "24 hours"
        case .standard: "14 days"
        case .pro: "30 days"
        }
    }
}

/// The TorBox plan Dove works with: the one `user/me` reported, unless the user picked another in Settings.
/// Stored as JSON in the Keychain (`CredentialKey.torBoxPlan`) so the share extension builds the same backend.
public struct TorBoxPlanSetting: Sendable, Hashable, Codable {
    public var detected: TorBoxPlan?
    public var chosen: TorBoxPlan?

    public init(detected: TorBoxPlan? = nil, chosen: TorBoxPlan? = nil) {
        self.detected = detected
        self.chosen = chosen
    }

    public var plan: TorBoxPlan? { chosen ?? detected }

    /// Whether NZBs go to TorBox. `toggle` is `CredentialKey.torBoxUsenet`: "1" on, "0" off, nil not set.
    /// A known plan without Usenet turns it off; Pro turns it on unless the user turned it off.
    /// With no plan known only the toggle counts.
    public func usenet(toggle: String?) -> Bool {
        guard let plan else { return toggle == "1" }
        return plan.includesUsenet && toggle != "0"
    }
}
