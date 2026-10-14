import Foundation
import Testing
@testable import DoveKit

struct AccountStatusTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    @Test func realDebridReadsTypeAndExpiration() async throws {
        let transport = MockTransport()
        await transport.stub("1.0/user", json: #"""
        {"id":1,"username":"u","email":"e","points":10,"locale":"en","avatar":"","type":"premium",
         "premium":2592000,"expiration":"2026-11-13T12:00:00.000Z"}
        """#)
        let account = try await RealDebridBackend(apiKey: "k", transport: transport).account()

        #expect(account.isPremium)
        #expect(account.premiumUntil == AccountDate.parse("2026-11-13T12:00:00Z"))
        #expect(account.daysLeft(now: AccountDate.parse("2026-10-14T12:00:00Z")!, calendar: utc) == 30)
    }

    @Test func realDebridFreeAccountHasNoEnd() async throws {
        let transport = MockTransport()
        await transport.stub("1.0/user", json: #"{"type":"free","premium":0,"expiration":"2020-01-01T00:00:00.000Z"}"#)
        let account = try await RealDebridBackend(apiKey: "k", transport: transport).account()

        #expect(!account.isPremium)
        #expect(account.premiumUntil == nil)
        #expect(account.daysLeft() == nil)
    }

    @Test func torBoxReadsPlanAndExpiry() async throws {
        let transport = MockTransport()
        await transport.stub("user/me", json: #"""
        {"success":true,"error":null,"detail":"ok","data":{"id":1,"plan":2,"is_subscribed":true,
         "premium_expires_at":"2027-01-01T00:00:00Z"}}
        """#)
        let account = try await TorBoxBackend(apiKey: "k", transport: transport).account()

        #expect(account.isPremium)
        #expect(account.plan == "Pro")
        #expect(account.premiumUntil == AccountDate.parse("2027-01-01T00:00:00Z"))
    }

    @Test func torBoxFreePlanIsNotPremium() async throws {
        let transport = MockTransport()
        await transport.stub("user/me", json: #"{"success":true,"data":{"plan":0,"premium_expires_at":null}}"#)
        let account = try await TorBoxBackend(apiKey: "k", transport: transport).account()

        #expect(!account.isPremium)
        #expect(account.plan == nil)
    }

    @Test func offcloudReadsAPlainDay() async throws {
        let transport = MockTransport()
        await transport.stub("account/info", json: #"{"user_id":"u","email":"e","is_premium":true,"expiration_date":"2026-12-24","can_download":true}"#)
        let account = try await OffcloudBackend(apiKey: "k", transport: transport).account()

        #expect(account.isPremium)
        #expect(account.daysLeft(now: AccountDate.parse("2026-12-14")!, calendar: utc) == 10)
    }

    @Test func expiredPremiumHasZeroDaysLeft() {
        let account = AccountStatus(isPremium: true, premiumUntil: AccountDate.parse("2026-01-01"))
        #expect(account.daysLeft(now: AccountDate.parse("2026-02-01")!) == 0)
    }
}
