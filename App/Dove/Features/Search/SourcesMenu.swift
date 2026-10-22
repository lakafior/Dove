import DoveAppCore
import DoveKit
import SwiftUI

/// Which sources a search category asks: the Stremio addons (Movies & TV only) and each indexer enabled in
/// Settings, with today's API hits, so limited indexers are spent only where they help. Remembered per
/// category; the menu stays open while sources are switched.
struct SourcesMenu: View {
    @Environment(AppModel.self) private var model
    let category: SearchCategory
    /// Changes when a search finishes, so the hit counts are read again.
    var refresh: Bool = false
    @State private var usages: [String: NewznabSearch.Usage] = [:]

    private var indexers: [NewznabIndexer] {
        model.newznabIndexers.filter(\.enabled)
    }

    var body: some View {
        let count = model.sourceSelection.count(in: category, indexers: model.newznabIndexers)
        Menu {
            if category.usesAddons {
                Section {
                    Toggle("Stremio addons", isOn: binding(for: SourceSelection.addons))
                }
            }
            ForEach(NewznabIndexer.Kind.allCases, id: \.self) { kind in
                let ofKind = indexers.filter { $0.kind == kind }
                if !ofKind.isEmpty {
                    Section(kind.displayName) {
                        ForEach(ofKind) { indexer in
                            Toggle(isOn: binding(for: indexer.id)) {
                                Text(indexer.name)
                                if let hits = hitsLine(for: indexer) { Text(hits) }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("\(count.on)/\(count.total)", systemImage: count.on == 0 ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                .labelStyle(.titleAndIcon)
        }
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Sources, \(count.on) of \(count.total) on")
        .task(id: refresh) { usages = await model.newznab.usages() }
    }

    private func binding(for source: String) -> Binding<Bool> {
        Binding(
            get: { model.sourceSelection.isOn(source, in: category) },
            set: { model.sourceSelection.set(source, on: $0, in: category) }
        )
    }

    /// "72 of 100 left today", "8 today" without a limit, or why the indexer rests until tomorrow.
    private func hitsLine(for indexer: NewznabIndexer) -> String? {
        let usage = usages[indexer.id]
        if usage?.blocked == true { return "Limit reached, back tomorrow" }
        let hits = usage?.hits ?? 0
        if let limit = indexer.dailyLimit { return "\(max(limit - hits, 0)) of \(limit) left today" }
        return hits > 0 ? "\(hits) used today" : nil
    }
}
