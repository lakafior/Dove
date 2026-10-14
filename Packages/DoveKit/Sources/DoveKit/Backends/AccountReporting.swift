import Foundation

/// A debrid account's plan: premium or not, and until when.
public struct AccountStatus: Sendable, Hashable, Codable {
    public var isPremium: Bool
    /// Nil when the service does not say (or the plan does not expire).
    public var premiumUntil: Date?
    /// The service's plan name when it has several ("Pro", "Essential").
    public var plan: String?

    public init(isPremium: Bool, premiumUntil: Date? = nil, plan: String? = nil) {
        self.isPremium = isPremium
        self.premiumUntil = premiumUntil
        self.plan = plan
    }

    /// Whole days of premium left (0 on the last day), nil without an end date or premium.
    public func daysLeft(now: Date = .now, calendar: Calendar = .current) -> Int? {
        guard isPremium, let premiumUntil else { return nil }
        guard premiumUntil > now else { return 0 }
        return calendar.dateComponents([.day], from: now, to: premiumUntil).day ?? 0
    }
}

/// Services that tell how long the account's premium lasts (Real-Debrid, TorBox, Offcloud, Debrid-Link). nzbdav has no account.
public protocol AccountReporting: LibraryBackend {
    func account() async throws -> AccountStatus
}

enum AccountDate {
    /// ISO 8601 (with or without fractions), or a plain day (`2026-01-01`, read as UTC midnight).
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = APIDate.parse(string) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: String(string.prefix(10)))
    }
}
