import CoreGraphics

/// Sizes on the start page, from the window's width: a small window keeps the compact sizes, a large one widens the
/// content and grows the posters, the field and the cards instead of leaving empty sides.
struct HomeLayout: Equatable {
    /// The page's width.
    var width: CGFloat = 1200

    /// The content column, with 32 pt margins, up to 1800 pt.
    var contentWidth: CGFloat { min(max(width - 64, 600), 1800) }

    /// 1 up to about 1200 pt of content, growing to 1.5 at 1800.
    var scale: CGFloat { min(max(contentWidth / 1200, 1), 1.5) }

    var fieldWidth: CGFloat { 760 * scale }
    /// Height of a cover in the poster rows; widths follow each kind's ratio.
    var posterHeight: CGFloat { 204 * scale }
    /// Smallest width of a result poster in the search grid.
    var resultWidth: CGFloat { 150 * scale }
    var shelfMinimum: CGFloat { 230 * scale }
    var shelfHeight: CGFloat { 124 * scale }
}
