import DoveKit
import SwiftUI

/// Small colored tag naming a service: RD, TB, OC, DL, ND.
struct BackendBadge: View {
    let backend: BackendID

    var body: some View {
        Text(abbreviation)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
            .accessibilityLabel(backend.displayName)
    }

    private var abbreviation: String {
        switch backend {
        case .realDebrid: "RD"
        case .torBox: "TB"
        case .offcloud: "OC"
        case .debridLink: "DL"
        case .nzbdav: "ND"
        }
    }

    private var color: Color {
        switch backend {
        case .realDebrid: .green
        case .torBox: .purple
        case .offcloud: .blue
        case .debridLink: .teal
        case .nzbdav: .orange
        }
    }
}
