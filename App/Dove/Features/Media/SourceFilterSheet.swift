import DoveKit
import SwiftUI

/// Chips for every value present in the current list, per dimension. Choices persist (AppModel.sourceFilter).
struct SourceFilterSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let groups: [StreamGroup]

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Sort", selection: $model.sourceFilter.sort) {
                        ForEach(SourceFilter.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Toggle("Apple TV friendly", isOn: $model.sourceFilter.appleTVFriendly)
                } footer: {
                    Text("Apple TV friendly hides AV1 and TrueHD Atmos releases.")
                }

                ForEach(SourceFilter.Dimension.allCases, id: \.self) { dimension in
                    let options = SourceFilter.options(for: dimension, in: groups)
                    if !options.isEmpty {
                        Section(dimension.title) {
                            FlowLayout(spacing: 6) {
                                ForEach(options, id: \.value) { option in
                                    Chip(
                                        text: "\(option.value) \(option.count)",
                                        isOn: model.sourceFilter.isSelected(option.value, in: dimension)
                                    ) {
                                        model.sourceFilter.toggle(option.value, in: dimension)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { model.sourceFilter.reset() }
                        .disabled(!model.sourceFilter.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
