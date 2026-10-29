import DoveKit
import Foundation
import Observation

/// Speed tests of the configured services, one at a time, on a big file from each one's library. Results stay on
/// this device (UserDefaults): another network gives other numbers.
@MainActor
@Observable
public final class SpeedTestModel {
    public private(set) var samples: [BackendID: SpeedSample]
    /// Why the last test of a service failed.
    public private(set) var failures: [BackendID: String] = [:]
    /// The service being measured now.
    public private(set) var testing: BackendID?
    public private(set) var isRunning = false

    private static let key = "speedSamples"
    private let meter: any ThroughputMeasuring

    public init(meter: any ThroughputMeasuring = URLSessionThroughput()) {
        self.meter = meter
        samples = DoveStorage.defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([BackendID: SpeedSample].self, from: $0) } ?? [:]
    }

    /// Measures `ids` in order with the library's items. Stops at the first Wi-Fi error: the rest would fail too.
    public func run(_ ids: [BackendID], using model: AppModel) async {
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            testing = nil
        }
        let items = model.library.items.map(\.item)
        for id in ids {
            guard let backend = model.backend(id) else { continue }
            testing = id
            failures[id] = nil
            do {
                samples[id] = try await SpeedTest.run(on: backend, items: items, meter: meter)
                save()
            } catch is CancellationError {
                return
            } catch {
                failures[id] = error.localizedDescription
                if error.localizedDescription.contains("Wi-Fi") { return }
            }
        }
    }

    /// "312 Mb/s · Enough for 4K remux · 5 min ago".
    public func summary(_ id: BackendID) -> String? {
        guard let sample = samples[id] else { return nil }
        let speed = sample.megabitsPerSecond.formatted(.number.precision(.fractionLength(0)))
        let age = sample.measuredAt.formatted(.relative(presentation: .named))
        return "\(speed) Mb/s · \(sample.verdict) · \(age)"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(samples) { DoveStorage.defaults.set(data, forKey: Self.key) }
    }
}
