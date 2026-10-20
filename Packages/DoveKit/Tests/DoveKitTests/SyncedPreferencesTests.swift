import Foundation
import Testing
@testable import DoveKit

struct SyncedPreferencesTests {
    @Test func roundTripsAndToleratesMissingOrUnknownFields() throws {
        var preferences = SyncedPreferences()
        preferences.downloadOnly = true
        preferences.aioStreamsVariant = "dove"
        preferences.showAdult = true
        preferences.sourceFilter.toggle("2160p", in: .resolution)
        preferences.readIn = .kindle
        preferences.kindleAddress = "me@kindle.com"
        preferences.pocketBookAddress = "me@pbsync.com"
        preferences.emailAddress = "me@example.com"
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(SyncedPreferences.self, from: data) == preferences)

        let partial = try JSONDecoder().decode(SyncedPreferences.self, from: Data(#"{"downloadOnly":true,"futureField":1}"#.utf8))
        #expect(partial.downloadOnly)
        #expect(partial.aioStreamsVariant.isEmpty)
        #expect(!partial.showAdult)
        #expect(partial.sourceFilter == SourceFilter())
        #expect(partial.readIn == nil)
        #expect(partial.kindleAddress.isEmpty)
        #expect(partial.pocketBookAddress.isEmpty)
        #expect(partial.emailAddress.isEmpty)
    }
}
