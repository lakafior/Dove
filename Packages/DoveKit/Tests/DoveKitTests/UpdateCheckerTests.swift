import Foundation
import Testing
@testable import DoveKit

struct UpdateCheckerTests {
    @Test func versionComparisonIsNumericAndPadsMissingComponents() throws {
        #expect(try #require(AppVersion("1.0.10")) > #require(AppVersion("1.0.9")))
        #expect(AppVersion("v1.2") == AppVersion("1.2.0"))
        #expect(AppVersion("1.0.0") == AppVersion("1.0"))
    }

    @Test func decodesReleaseAndBuildsRequest() async throws {
        let transport = MockTransport()
        await transport.stub("releases/latest", body: try Fixture.data("github_latest_release"))
        let update = try #require(try await UpdateChecker(transport: transport).latest(newerThan: AppVersion("1.1.0")!))
        #expect(update.version == AppVersion("1.2.0"))
        #expect(update.name == "Dove 1.2.0")
        #expect(update.notes.contains("better library"))
        #expect(update.dmgURL?.lastPathComponent == "Dove.dmg")
        #expect(update.publishedAt != nil)
        let request = try #require(await transport.requests.last)
        #expect(request.url?.absoluteString == "https://api.github.com/repos/lakafior/Dove/releases/latest")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Dove")
    }

    @Test func sameOrOlderReleaseIsNotAnUpdate() async throws {
        let transport = MockTransport()
        await transport.stub("releases/latest", body: try Fixture.data("github_latest_release"))
        let checker = UpdateChecker(transport: transport)
        #expect(try await checker.latest(newerThan: AppVersion("1.2")!) == nil)
        #expect(try await checker.latest(newerThan: AppVersion("1.3")!) == nil)
    }

    @Test func missingReleaseIsNilAndRateLimitIsReadable() async throws {
        let missing = MockTransport()
        await missing.stub("releases/latest", status: 404, json: "{}")
        #expect(try await UpdateChecker(transport: missing).latest(newerThan: AppVersion("1.0")!) == nil)
        for status in [403, 429] {
            let limited = MockTransport()
            await limited.stub("releases/latest", status: status, json: "{}")
            await #expect(throws: BackendError.api(message: "GitHub's limit for update checks was reached. Try again later.")) {
                try await UpdateChecker(transport: limited).latest(newerThan: AppVersion("1.0")!)
            }
        }
    }
}
