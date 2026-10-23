import DoveAppCore
import DoveKit
import SwiftUI

/// "Play in…": the usable players other than the default, for a one-off. Hidden when there are none.
struct PlayInMenu: View {
    @Environment(AppModel.self) private var model
    let play: (ExternalPlayer) -> Void

    var body: some View {
        let others = model.playback.otherPlayers
        if !others.isEmpty {
            Menu("Play in…", systemImage: "play.rectangle.on.rectangle") {
                ForEach(others) { player in
                    Button(player.displayName) { play(player) }
                }
            }
        }
    }
}
