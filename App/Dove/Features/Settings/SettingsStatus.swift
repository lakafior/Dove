import SwiftUI

/// What a "Save and test" button found, shown under it.
enum SettingsStatus: Equatable {
    case testing
    case success(String)
    case failure(String)
    /// Neither good nor bad news ("Key removed.").
    case note(String)

    init(_ error: any Error) {
        self = .failure(error.localizedDescription)
    }
}

/// A status line: a checkmark or a warning sign with a colour, so it reads the same with VoiceOver.
struct SettingsStatusView: View {
    let status: SettingsStatus

    var body: some View {
        Group {
            switch status {
            case .testing:
                Text("Testing…").foregroundStyle(.secondary)
            case .success(let text):
                Label {
                    Text(text)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            case .failure(let text):
                Label {
                    Text(text)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            case .note(let text):
                Text(text).foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }
}
