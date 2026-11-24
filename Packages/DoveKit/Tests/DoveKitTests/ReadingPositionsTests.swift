import Foundation
import Testing
@testable import DoveKit

struct ReadingPositionsTests {
    @Test func keepsTheNewerPlaceOfEachBook() {
        var here = ReadingPositions()
        here.set(ReadingPosition(location: "epubcfi(/6/4!/4/2:0)", progress: 0.1, updatedAt: Date(timeIntervalSince1970: 100)), for: "solaris")
        here.set(ReadingPosition(location: "page:3", progress: 0.3, updatedAt: Date(timeIntervalSince1970: 300)), for: "dune")
        var there = ReadingPositions()
        there.set(ReadingPosition(location: "epubcfi(/6/20!/4/2:0)", progress: 0.6, updatedAt: Date(timeIntervalSince1970: 200)), for: "solaris")
        there.set(ReadingPosition(location: "page:1", progress: 0.1, updatedAt: Date(timeIntervalSince1970: 50)), for: "dune")

        here.merge(there)
        #expect(here["solaris"]?.location == "epubcfi(/6/20!/4/2:0)")
        #expect(here["dune"]?.page == 3)
    }

    @Test func savesThroughTheKeychainWithoutLosingAnotherDevicesBooks() {
        let keychain = KeychainStore.inMemory()
        SharedConfiguration.saveReadingPosition(.page(12, of: 48), for: "dune", to: keychain)
        SharedConfiguration.saveReadingPosition(ReadingPosition(location: "epubcfi(/6/2!)", progress: 2), for: "solaris", to: keychain)

        let positions = SharedConfiguration.readingPositions(from: keychain)
        #expect(positions["dune"]?.page == 12)
        #expect(positions["dune"]?.progress == 0.25)
        #expect(positions["solaris"]?.progress == 1)
        #expect(ReadingPosition(location: "page:0", progress: nil).page == nil)
    }

    @Test func dovesReaderIsNotAMailTarget() throws {
        #expect(!ReadingTarget.dove.isMail)
        #expect(!ReadingTarget.appleBooks.isMail)
        #expect(ReadingTarget.kindle.isMail)
        #expect(ReadingTarget.dove.formats == ["epub", "pdf"])
        // An older install reads a preference it does not know as "ask every time", not as an error.
        #expect(try JSONDecoder().decode(SyncedPreferences.self, from: Data(#"{"readIn": "dove"}"#.utf8)).readIn == .dove)
    }
}
