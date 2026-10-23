import DoveAppCore
import DoveKit
import SwiftUI

/// The described filter's field, with its own state: typing redraws this row, not the whole source list.
struct DescribeSourcesField: View {
    let groups: [StreamGroup]
    let onRequest: (SourceRequest) -> Void
    @State private var description = ""
    @State private var isDescribing = false
    @State private var describeError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.secondary)
                TextField("Describe it: 4K DV, no Atmos, under 20 GB", text: $description)
                    .submitLabel(.search)
                    .onSubmit(describe)
                    .disabled(isDescribing)
                if isDescribing { ProgressView() }
            }
            if let describeError {
                Text(describeError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func describe() {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isDescribing = true
        describeError = nil
        Task {
            defer { isDescribing = false }
            do {
                onRequest(try await DescribedFilter.request(for: text, groups: groups))
            } catch {
                describeError = error.localizedDescription
            }
        }
    }
}
