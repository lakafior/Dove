import Foundation
import Testing
@testable import DoveKit

@Suite struct DemoModeTests {
    @Test func inMemoryKeychainRoundTripsAndRemovesValues() throws {
        let keychain = KeychainStore.inMemory()
        try keychain.set("demo-token", for: .realDebridAPIKey)
        #expect(try keychain.get(.realDebridAPIKey) == "demo-token")
        try keychain.set(nil, for: .realDebridAPIKey)
        #expect(try keychain.get(.realDebridAPIKey) == nil)
    }

    @Test func inMemoryKeychainsDoNotShareValues() throws {
        let first = KeychainStore.inMemory()
        let second = KeychainStore.inMemory()
        try first.set("demo-token", for: .realDebridAPIKey)
        #expect(try second.get(.realDebridAPIKey) == nil)
    }

    @Test func isInactiveInTests() {
        #expect(!DemoMode.isActive)
    }

    @Test func applicationSupportMatchesExistingLocationOutsideDemoMode() {
        #expect(DoveStorage.applicationSupport == URL.applicationSupportDirectory.appending(path: "Dove"))
    }
}
