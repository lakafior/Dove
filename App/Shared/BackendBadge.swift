import DoveKit
import SwiftUI

/// Small colored tag naming a service: RD, TB, OC, DL, ND. Also compiled into `DoveWidgets`.
struct BackendBadge: View {
    let backend: BackendID

    var body: some View {
        Text(backend.abbreviation)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(backend.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(backend.tint)
            .accessibilityLabel(backend.displayName)
    }
}

extension BackendID {
    var abbreviation: String {
        switch self {
        case .realDebrid: "RD"
        case .torBox: "TB"
        case .offcloud: "OC"
        case .debridLink: "DL"
        case .premiumize: "PM"
        case .allDebrid: "AD"
        case .nzbdav: "ND"
        case .iCloudDrive: "iC"
        }
    }

    var tint: Color {
        switch self {
        case .realDebrid: .green
        case .torBox: .purple
        case .offcloud: .blue
        case .debridLink: .teal
        case .premiumize: .red
        case .allDebrid: .yellow
        case .nzbdav: .orange
        case .iCloudDrive: .cyan
        }
    }
}

extension DownloadDestination {
    var symbol: String {
        switch self {
        case .device: "iphone"
        case .iCloud: "icloud"
        }
    }
}

extension FilePlace {
    var symbol: String {
        switch self {
        case .download(let destination): destination.symbol
        case .service: "cloud"
        }
    }
}
