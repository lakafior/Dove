import Foundation
import Testing
@testable import DoveKit

struct SpeedTestTests {
    /// Records the request and answers a fixed speed.
    private final class FakeMeter: ThroughputMeasuring, @unchecked Sendable {
        var requests: [URLRequest] = []
        func measure(_ request: URLRequest, maxBytes: Int64, maxDuration: TimeInterval) async throws -> Throughput {
            requests.append(request)
            return Throughput(bytes: maxBytes, seconds: 2, bitsPerSecond: 250_000_000)
        }
    }

    /// A backend whose list has no files; `item` adds them, and `downloadRequest` builds a link from the file ID.
    private actor ListBackend: LibraryBackend {
        nonisolated let id: BackendID = .realDebrid
        nonisolated let supportedSources: Set<SourceKind> = [.torrent]
        let listed: [LibraryItem]
        let detailed: [LibraryItem.ID: [LibraryFile]]
        private(set) var lookups: [LibraryItem.ID] = []

        init(listed: [LibraryItem], detailed: [LibraryItem.ID: [LibraryFile]]) {
            self.listed = listed
            self.detailed = detailed
        }

        func validateCredentials() async throws {}
        func add(_ source: Source) async throws -> LibraryItem.ID { "x" }
        func items() async throws -> [LibraryItem] { listed }
        func item(_ itemID: LibraryItem.ID) async throws -> LibraryItem {
            lookups.append(itemID)
            var item = listed.first { $0.id == itemID }!
            item.files = detailed[itemID] ?? []
            return item
        }
        func delete(_ itemID: LibraryItem.ID) async throws {}
        func downloadRequest(itemID: LibraryItem.ID, fileID: LibraryFile.ID) async throws -> URLRequest {
            URLRequest(url: URL(string: "https://dl.example/\(itemID)/\(fileID)")!)
        }
    }

    private let mb: Int64 = 1024 * 1024

    private func item(_ id: String, size: Int64, status: LibraryItem.Status = .ready, files: [LibraryFile] = []) -> LibraryItem {
        LibraryItem(id: id, backend: .realDebrid, name: id, size: size, status: status, files: files)
    }

    @Test func calculatorCountsFromTheFirstByte() {
        var calculator = ThroughputCalculator()
        // A slow first answer (connection, TTFB) does not count; then 10 MB a second.
        calculator.add(1_000_000, at: 5)
        calculator.add(5_000_000, at: 5.5)
        calculator.add(5_000_000, at: 6)
        #expect(calculator.totalBytes == 11_000_000)
        #expect(calculator.bitsPerSecond == 80_000_000)
        #expect(calculator.elapsed(at: 7) == 2)
    }

    @Test func oneChunkIsNotASpeed() {
        var calculator = ThroughputCalculator()
        calculator.add(100, at: 1)
        #expect(calculator.bitsPerSecond == nil)
    }

    @Test func picksTheBiggestVideoAndAsksForItsStart() async throws {
        let backend = ListBackend(listed: [
            item("small", size: 10 * mb, files: [LibraryFile(id: "s", name: "s.mkv", size: 10 * mb)]),
            item("busy", size: 90_000 * mb, status: .downloading(progress: 0.5)),
            item("movie", size: 20_000 * mb, files: [
                LibraryFile(id: "sample", name: "Sample/sample.mkv", size: 60 * mb),
                LibraryFile(id: "main", name: "Movie.mkv", size: 19_000 * mb),
                LibraryFile(id: "iso", name: "Extras.iso", size: 25_000 * mb),
            ]),
        ], detailed: [:])
        let meter = FakeMeter()

        let sample = try await SpeedTest.run(on: backend, items: backend.items(), meter: meter, maxBytes: 100)

        #expect(sample.fileName == "Movie.mkv")
        #expect(sample.megabitsPerSecond == 250)
        #expect(sample.verdict == "Enough for 4K remux")
        let request = try #require(meter.requests.first)
        #expect(request.url?.absoluteString == "https://dl.example/movie/main")
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-99")
    }

    @Test func fetchesFilesForAFewItemsListedWithoutThem() async throws {
        let listed = (1...5).map { item("t\($0)", size: Int64(10 - $0) * 1000 * mb) }
        let backend = ListBackend(listed: listed, detailed: ["t3": [LibraryFile(id: "v", name: "v.mp4", size: 900 * mb)]])

        let sample = try await SpeedTest.run(on: backend, items: listed, meter: FakeMeter())

        #expect(sample.fileName == "v.mp4")
        #expect(await backend.lookups == ["t1", "t2", "t3"])
    }

    @Test func noBigReadyFileIsExplained() async {
        let backend = ListBackend(listed: [item("tiny", size: 5 * mb, files: [LibraryFile(id: "a", name: "a.mkv", size: 5 * mb)])], detailed: [:])
        await #expect(throws: SpeedTest.Failure.noTestFile(.realDebrid)) {
            try await SpeedTest.run(on: backend, items: backend.items(), meter: FakeMeter())
        }
    }

    @Test func orderPutsMeasuredServicesFastestFirst() {
        let samples: [BackendID: SpeedSample] = [
            .torBox: SpeedSample(backend: .torBox, bitsPerSecond: 300, bytes: 1, seconds: 1, fileName: "a"),
            .offcloud: SpeedSample(backend: .offcloud, bitsPerSecond: 500, bytes: 1, seconds: 1, fileName: "b"),
        ]
        let order = SpeedTest.ordered([.realDebrid, .torBox, .debridLink, .offcloud], by: samples)
        #expect(order == [.offcloud, .torBox, .realDebrid, .debridLink])
    }

    @Test func verdictThresholds() {
        let sample = { (mbps: Double) in SpeedSample(backend: .torBox, bitsPerSecond: mbps * 1_000_000, bytes: 1, seconds: 1, fileName: "f").verdict }
        #expect(sample(120) == "Enough for 4K remux")
        #expect(sample(60) == "Enough for 4K WEB-DL")
        #expect(sample(20) == "Enough for 1080p")
        #expect(sample(8) == "May stutter in HD")
    }
}
