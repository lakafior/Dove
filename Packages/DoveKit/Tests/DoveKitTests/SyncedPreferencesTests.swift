import Foundation
import Testing
@testable import DoveKit

struct SyncedPreferencesTests {
    @Test func roundTripsAndToleratesMissingOrUnknownFields() throws {
        var preferences = SyncedPreferences()
        preferences.downloadOnly = true
        preferences.aioStreamsVariant = "dove"
        preferences.sourceFilter.toggle("2160p", in: .resolution)
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(SyncedPreferences.self, from: data) == preferences)

        let partial = try JSONDecoder().decode(SyncedPreferences.self, from: Data(#"{"downloadOnly":true,"futureField":1}"#.utf8))
        #expect(partial.downloadOnly)
        #expect(partial.aioStreamsVariant.isEmpty)
        #expect(partial.sourceFilter == SourceFilter())
    }
}
