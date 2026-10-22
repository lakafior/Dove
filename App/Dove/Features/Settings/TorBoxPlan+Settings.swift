import DoveKit

extension TorBoxPlan {
    /// What the plan means for Dove.
    var features: String {
        let seeding = seedingTimeText.map { "seeds finished torrents for \($0), so private trackers can go here" } ?? "no seeding"
        let usenet = includesUsenet ? "Usenet included" : "no Usenet"
        return "\(usenet), \(seeding)"
    }
}
