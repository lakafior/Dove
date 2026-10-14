import Foundation

/// How fast one service delivered a file to this device, on this network, at one moment.
public struct SpeedSample: Codable, Sendable, Equatable {
    public var backend: BackendID
    public var bitsPerSecond: Double
    public var bytes: Int64
    public var seconds: Double
    public var measuredAt: Date
    /// The file it was measured on.
    public var fileName: String

    public init(backend: BackendID, bitsPerSecond: Double, bytes: Int64, seconds: Double, measuredAt: Date = .now, fileName: String) {
        self.backend = backend
        self.bitsPerSecond = bitsPerSecond
        self.bytes = bytes
        self.seconds = seconds
        self.measuredAt = measuredAt
        self.fileName = fileName
    }

    public var megabitsPerSecond: Double { bitsPerSecond / 1_000_000 }

    /// What this speed is enough for in Infuse (one connection): 4K remuxes need about 100 Mb/s, 4K WEB-DLs
    /// 25–40, 1080p 10–20.
    public var verdict: String {
        switch megabitsPerSecond {
        case 100...: "Enough for 4K remux"
        case 40..<100: "Enough for 4K WEB-DL"
        case 15..<40: "Enough for 1080p"
        default: "May stutter in HD"
        }
    }
}

/// Bytes over time, counted from the first byte so the time to connect and to get an answer does not count.
public struct ThroughputCalculator: Sendable {
    private var firstByteAt: TimeInterval?
    private var firstChunk: Int64 = 0
    private var lastAt: TimeInterval?
    public private(set) var totalBytes: Int64 = 0

    public init() {}

    public mutating func add(_ bytes: Int64, at time: TimeInterval) {
        if firstByteAt == nil {
            firstByteAt = time
            firstChunk = bytes
        }
        totalBytes += bytes
        lastAt = time
    }

    /// Seconds since the first byte.
    public func elapsed(at time: TimeInterval) -> TimeInterval {
        firstByteAt.map { time - $0 } ?? 0
    }

    /// Bytes after the first chunk over the time since it arrived. Nil until two chunks are apart in time.
    public var bitsPerSecond: Double? {
        guard let firstByteAt, let lastAt, lastAt > firstByteAt else { return nil }
        return Double(totalBytes - firstChunk) * 8 / (lastAt - firstByteAt)
    }

    public var seconds: Double {
        guard let firstByteAt, let lastAt else { return 0 }
        return lastAt - firstByteAt
    }
}

/// The result of downloading part of a file.
public struct Throughput: Sendable, Equatable {
    public var bytes: Int64
    public var seconds: Double
    public var bitsPerSecond: Double

    public init(bytes: Int64, seconds: Double, bitsPerSecond: Double) {
        self.bytes = bytes
        self.seconds = seconds
        self.bitsPerSecond = bitsPerSecond
    }
}

/// Downloads the start of a file for a while and reports the speed.
public protocol ThroughputMeasuring: Sendable {
    func measure(_ request: URLRequest, maxBytes: Int64, maxDuration: TimeInterval) async throws -> Throughput
}

/// Measures every configured service on a file from its library: the same CDN and kind of link Infuse plays from.
public enum SpeedTest {
    /// Enough to get past TCP slow start on a fast line without spending much of anyone's quota.
    public static let maxBytes: Int64 = 150 * 1024 * 1024
    public static let maxDuration: TimeInterval = 10
    /// Smaller files finish before the speed settles.
    static let minimumFileSize: Int64 = 50 * 1024 * 1024
    /// Items whose files are fetched (one call each) when the list did not include them (Real-Debrid, Offcloud).
    static let detailLookups = 3

    public enum Failure: LocalizedError, Equatable {
        case noTestFile(BackendID)

        public var errorDescription: String? {
            switch self {
            case .noTestFile(let backend):
                "\(backend.displayName) has no ready file of 50 MB or more to test with. Add something there first."
            }
        }
    }

    /// Picks a big ready file on `backend` (a video if there is one), downloads its start and reports the speed.
    public static func run(
        on backend: any LibraryBackend,
        items: [LibraryItem],
        meter: any ThroughputMeasuring,
        maxBytes: Int64 = maxBytes,
        maxDuration: TimeInterval = maxDuration
    ) async throws -> SpeedSample {
        guard let (item, file) = try await testFile(on: backend, items: items) else {
            throw Failure.noTestFile(backend.id)
        }
        var request = try await backend.downloadRequest(itemID: item.id, fileID: file.id)
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let result = try await meter.measure(request, maxBytes: maxBytes, maxDuration: maxDuration)
        return SpeedSample(
            backend: backend.id,
            bitsPerSecond: result.bitsPerSecond,
            bytes: result.bytes,
            seconds: result.seconds,
            fileName: (file.name as NSString).lastPathComponent
        )
    }

    /// The biggest ready items first; files from the list, or one detail call for up to `detailLookups` items.
    static func testFile(on backend: any LibraryBackend, items: [LibraryItem]) async throws -> (LibraryItem, LibraryFile)? {
        let ready = items
            .filter { $0.backend == backend.id && $0.status == .ready }
            .sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        var lookups = 0
        for item in ready {
            var files = item.files
            if files.isEmpty {
                guard lookups < detailLookups else { continue }
                lookups += 1
                files = (try? await backend.item(item.id).files) ?? []
            }
            if let file = bestFile(in: files) { return (item, file) }
        }
        return nil
    }

    /// The biggest video of at least `minimumFileSize`, else the biggest file of that size.
    static func bestFile(in files: [LibraryFile]) -> LibraryFile? {
        let big = files.filter { ($0.size ?? 0) >= minimumFileSize }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        return big.first { FileKind.isVideo($0.name) } ?? big.first
    }

    /// `order` with the measured services fastest first; the rest keep their places after them, in their order.
    public static func ordered(_ order: [BackendID], by samples: [BackendID: SpeedSample]) -> [BackendID] {
        let measured = order.filter { samples[$0] != nil }
            .sorted { (samples[$0]?.bitsPerSecond ?? 0) > (samples[$1]?.bitsPerSecond ?? 0) }
        return measured + order.filter { samples[$0] == nil }
    }
}

/// `ThroughputMeasuring` over its own ephemeral `URLSession`: Wi-Fi only (not cellular, not a hotspot), no cache,
/// stopped after `maxBytes` or `maxDuration` from the first byte.
public struct URLSessionThroughput: ThroughputMeasuring {
    public init() {}

    public func measure(_ request: URLRequest, maxBytes: Int64, maxDuration: TimeInterval) async throws -> Throughput {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        let meter = Meter(maxBytes: maxBytes, maxDuration: maxDuration)
        let session = URLSession(configuration: configuration, delegate: meter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            return try await withTaskCancellationHandler {
                try await meter.run(session.dataTask(with: request))
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch let error as URLError where [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
            || error.networkUnavailableReason != nil {
            throw BackendError.api(message: "Speed tests run on Wi-Fi only, so they measure the network your TV uses and spend no mobile data.")
        }
    }

    private final class Meter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maxBytes: Int64
        private let maxDuration: TimeInterval
        private let lock = NSLock()
        private var calculator = ThroughputCalculator()
        private var continuation: CheckedContinuation<Throughput, any Error>?
        private var finished = false

        init(maxBytes: Int64, maxDuration: TimeInterval) {
            self.maxBytes = maxBytes
            self.maxDuration = maxDuration
        }

        func run(_ task: URLSessionDataTask) async throws -> Throughput {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                task.resume()
            }
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            if let http = response as? HTTPURLResponse, let error = http.backendError {
                finish(.failure(error))
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let now = ProcessInfo.processInfo.systemUptime
            let done: Bool = lock.withLock {
                calculator.add(Int64(data.count), at: now)
                return calculator.totalBytes >= maxBytes || calculator.elapsed(at: now) >= maxDuration
            }
            if done {
                finish(nil)
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            // A file smaller than the limit ends on its own: that is a result too.
            finish(error.map { .failure($0) })
        }

        private func finish(_ failure: Result<Throughput, any Error>?) {
            let (continuation, result): (CheckedContinuation<Throughput, any Error>?, Result<Throughput, any Error>) = lock.withLock {
                guard !finished else { return (nil, .failure(CancellationError())) }
                finished = true
                defer { self.continuation = nil }
                if let failure { return (self.continuation, failure) }
                guard let speed = calculator.bitsPerSecond else {
                    return (self.continuation, .failure(BackendError.api(message: "The download was too short to measure.")))
                }
                return (self.continuation, .success(Throughput(bytes: calculator.totalBytes, seconds: calculator.seconds, bitsPerSecond: speed)))
            }
            continuation?.resume(with: result)
        }
    }
}
