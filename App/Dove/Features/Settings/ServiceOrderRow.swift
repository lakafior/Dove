import DoveKit
import SwiftUI

/// One service in an order list: why it is skipped, or its last measured speed.
struct ServiceOrderRow: View {
    @Environment(AppModel.self) private var model
    let id: BackendID
    /// Why the service is skipped, or nil when it takes part.
    let skipped: String?

    private var speed: SpeedTestModel { model.speed }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(id.displayName)
                Spacer()
                if let skipped {
                    Text(skipped).foregroundStyle(.secondary)
                } else if speed.testing == id {
                    ProgressView()
                }
            }
            if skipped == nil {
                if let failure = speed.failures[id] {
                    Text(failure).font(.caption).foregroundStyle(.red)
                } else if let summary = speed.summary(id) {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
