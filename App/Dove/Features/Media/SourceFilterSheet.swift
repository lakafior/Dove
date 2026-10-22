import DoveAppCore
import DoveKit
import SwiftUI

/// Chips for every value present in the current list, per dimension. The source list edits the persisted
/// `AppModel.sourceFilter`; Search › Other passes its own filter and only the dimensions that make sense there.
struct SourceFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filter: SourceFilter
    let groups: [StreamGroup]
    var dimensions: [SourceFilter.Dimension] = SourceFilter.Dimension.allCases
    var sorts: [SourceFilter.Sort] = SourceFilter.Sort.allCases
    var showsAppleTV = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sort", selection: $filter.sort) {
                        ForEach(sorts, id: \.self) { Text($0.title).tag($0) }
                    }
                    if showsAppleTV {
                        Toggle("Apple TV friendly", isOn: $filter.appleTVFriendly)
                    }
                } footer: {
                    if showsAppleTV {
                        Text("Apple TV friendly hides AV1 and TrueHD Atmos releases.")
                    }
                }

                ForEach(dimensions, id: \.self) { dimension in
                    let options = SourceFilter.options(for: dimension, in: groups)
                    // A single value filters nothing, unless it is already selected (so it can be turned off).
                    if options.count > 1 || options.contains(where: { filter.isSelected($0.value, in: dimension) }) {
                        Section {
                            FlowLayout(spacing: 6) {
                                ForEach(options, id: \.value) { option in
                                    Chip(
                                        text: "\(option.value) \(option.count)",
                                        isOn: filter.isSelected(option.value, in: dimension)
                                    ) {
                                        filter.toggle(option.value, in: dimension)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        } header: {
                            Text(dimension.title)
                        } footer: {
                            if let hint = dimension.hint { Text(hint) }
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { filter.reset() }
                        .disabled(!filter.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension SourceFilter.Dimension {
    var hint: String? {
        switch self {
        case .privacy: "Private and semi-private trackers want seeding back: Dove adds those only to a service that seeds (Settings › Order and fallback › Private trackers)."
        case .provider: "The addon or indexer that answered Dove (inside AIOStreams: the addon that found it)."
        case .tracker: "The tracker or Usenet indexer behind the result, when the source names it."
        default: nil
        }
    }
}

private struct Chip: View {
    let text: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}
