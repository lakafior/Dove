import DoveKit
import SwiftUI

/// Drag to reorder. "Automatic" adds try the services top to bottom.
struct DebridPriorityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                ForEach(model.debridOrder) { id in
                    HStack {
                        Text(id.displayName)
                        Spacer()
                        if !model.isConfigured(id) {
                            Text("No key").foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { model.debridOrder.move(fromOffsets: $0, toOffset: $1) }
            } footer: {
                Text("Torrents and links go to the first service. If it fails, Dove tries the next one. Services without a key are skipped.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Priority")
    }
}
