import DoveKit
import SwiftUI

extension BackendID {
    /// Services that fetch files, in the order Settings lists them.
    static let services: [BackendID] = [.realDebrid, .torBox, .offcloud, .debridLink, .premiumize, .allDebrid, .nzbdav]

    var settingsSymbol: String {
        switch self {
        case .realDebrid: "bolt.fill"
        case .torBox: "shippingbox.fill"
        case .offcloud: "cloud.fill"
        case .debridLink: "link"
        case .premiumize: "crown.fill"
        case .allDebrid: "a.circle.fill"
        case .nzbdav: "server.rack"
        case .iCloudDrive: "icloud.fill"
        case .calibre: "books.vertical.fill"
        }
    }

    var settingsColor: Color {
        switch self {
        case .realDebrid: .green
        case .torBox: .purple
        case .offcloud: .blue
        case .debridLink: .teal
        case .premiumize: .red
        case .allDebrid: .yellow
        case .nzbdav: .orange
        case .iCloudDrive: .cyan
        case .calibre: .brown
        }
    }

    /// Where the user finds the key.
    var keyHelp: String {
        switch self {
        case .realDebrid: "real-debrid.com › My account › API token (real-debrid.com/apitoken)."
        case .torBox: "torbox.app › Settings › API key."
        case .offcloud: "offcloud.com › Account › API key."
        case .debridLink: "debrid-link.com › My account › API key. Debrid-Link seeds, so torrents from private trackers can go here."
        case .premiumize: "premiumize.me › Account › API key. Every plan includes Usenet."
        case .allDebrid: "alldebrid.com › Account › API keys (alldebrid.com/apikeys). A new key may need confirming from the e-mail AllDebrid sends."
        case .nzbdav, .iCloudDrive, .calibre: ""
        }
    }

    /// Debrids that can take NZBs too, behind a switch on their page.
    var offersUsenet: Bool {
        [.torBox, .offcloud, .premiumize].contains(self)
    }
}
