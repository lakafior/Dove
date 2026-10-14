import Foundation
import Testing
@testable import DoveKit

struct ImageCacheTests {
    private let poster = URL(string: "https://image.tmdb.org/t/p/w342/p1.jpg")!

    private func makeCache(_ transport: MockTransport) -> (ImageCache, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "dove-tests/images-\(UUID().uuidString)")
        return (ImageCache(directory: directory, transport: transport), directory)
    }

    @Test func downloadsOnceThenReadsFromDisk() async throws {
        let transport = MockTransport()
        await transport.stub("w342/p1.jpg", body: Data([1, 2, 3]), contentType: "image/jpeg")
        let (cache, directory) = makeCache(transport)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await cache.data(for: poster)
        let second = try await cache.data(for: poster)

        #expect(first == Data([1, 2, 3]))
        #expect(second == first)
        #expect(await transport.requests.count == 1)
        #expect(await cache.contains(poster))

        // A new cache over the same folder (next launch) still has it.
        let relaunched = ImageCache(directory: directory, transport: transport)
        _ = try await relaunched.data(for: poster)
        #expect(await transport.requests.count == 1)
    }

    @Test func errorsAreNotStored() async throws {
        let transport = MockTransport()
        await transport.stub("w342/p1.jpg", status: 404, json: "{}")
        await transport.stub("w342/p1.jpg", body: Data([9]), contentType: "image/jpeg")
        let (cache, directory) = makeCache(transport)
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: (any Error).self) { try await cache.data(for: poster) }
        #expect(await !cache.contains(poster))
        #expect(try await cache.data(for: poster) == Data([9]))
    }

    @Test func removeAllEmptiesTheFolder() async throws {
        let transport = MockTransport()
        await transport.stub("w342/p1.jpg", body: Data([1]), contentType: "image/jpeg")
        let (cache, directory) = makeCache(transport)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await cache.data(for: poster)
        #expect(await cache.size() == 1)
        await cache.removeAll()
        #expect(await cache.size() == 0)
        #expect(await !cache.contains(poster))
    }
}
