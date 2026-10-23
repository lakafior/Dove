import SwiftUI

/// A slight rise under the pointer, so cards feel clickable. Still with Reduce Motion.
struct HoverLift: ViewModifier {
    var scale: CGFloat
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && !reduceMotion ? scale : 1)
            .shadow(color: .black.opacity(isHovered ? 0.35 : 0), radius: 10, y: 6)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
            .contentShape(.rect)
    }
}

extension View {
    func hoverLift(scale: CGFloat = 1.04) -> some View {
        modifier(HoverLift(scale: scale))
    }
}
