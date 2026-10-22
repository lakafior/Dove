import DoveAppCore
import DoveKit
import SwiftUI

/// A small coloured dot: green online, orange worth a look, red offline, grey not known yet.
struct StatusLight: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 2)
            .accessibilityHidden(true)
    }
}

extension ServiceStatusModel {
    func light(_ backend: BackendID) -> Color {
        switch health(of: backend) {
        case .offline: .red
        case .unknown: needsAttention(backend) ? .orange : .gray
        case .online: needsAttention(backend) ? .orange : .green
        }
    }
}
