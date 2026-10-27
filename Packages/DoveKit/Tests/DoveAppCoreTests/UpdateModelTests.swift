import DoveAppCore
import DoveKit
import Foundation
import MediaPlayer
import Testing

@MainActor
struct UpdateModelTests {
    @Test func automaticCheckHonorsTwentyFourHourThrottle() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let defaults = defaults()
        defaults.set(now.addingTimeInterval(-23 * 60 * 60), forKey: "updateLastCheck")
        let transport = ReleaseTransport()
        let model = UpdateModel(platform: TestPlatform(), transport: transport, defaults: defaults, now: { now }, currentVersion: AppVersion("1.0")!)
        await model.checkAutomatically()
        #expect(await transport.count == 0)
    }

    @Test func automaticCheckSkipsTheStoredTag() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let defaults = defaults()
        defaults.set("v1.2.0", forKey: "updateSkippedTag")
        let model = UpdateModel(platform: TestPlatform(), transport: ReleaseTransport(), defaults: defaults, now: { now }, currentVersion: AppVersion("1.0")!)
        await model.checkAutomatically()
        #expect(model.available == nil)
    }

    private func defaults() -> UserDefaults {
        let name = "UpdateModelTests.\(UUID().uuidString)"
        let value = UserDefaults(suiteName: name)!
        value.removePersistentDomain(forName: name)
        return value
    }
}

private actor ReleaseTransport: HTTPTransport {
    private(set) var count = 0
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let data = try Data(contentsOf: Bundle.module.url(forResource: "github_latest_release", withExtension: "json", subdirectory: "Fixtures")!)
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private final class TestPlatform: AppPlatform {
    var downloadsDirectory: URL = .temporaryDirectory
    func canOpen(_ url: URL) -> Bool { true }
    func open(_ url: URL) async -> Bool { true }
    func show(_ destination: AppModel.Destination) {}
    func libraryChanged() {}
    func servicesChanged(hasServices: Bool) async {}
    func libraryUpdated(_ app: AppModel) {}
    func accountsUpdated(_ app: AppModel) {}
    func downloadsChanged(_ records: [DownloadRecord]) {}
    func audiobookStarted() {}
    func nowPlayingArtwork(from data: Data) -> MPMediaItemArtwork? { nil }
}
