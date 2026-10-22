import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension EnvironmentValues {
    /// How much larger than usual text should be. 1 everywhere except the Mac's start page on a large window
    /// (`HomeLayout.scale`), where captions would otherwise look small under the bigger posters.
    @Entry var textScale: CGFloat = 1
}

extension View {
    /// A text style that grows with `textScale`; at 1 it is exactly `.font(.style.weight(weight))`.
    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledFont(style: style, weight: weight))
    }
}

private struct ScaledFont: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        content.font(font)
    }

    private var font: Font {
        guard scale != 1 else {
            let font = Font.system(style)
            return weight.map { font.weight($0) } ?? font
        }
        // Headline is the one bold text style; at a given size the weight has to be said.
        return .system(size: Self.pointSize(of: style) * scale, weight: weight ?? (style == .headline ? .bold : .regular))
    }

    /// The style's size on this platform, the base the scale multiplies.
    private static func pointSize(of style: Font.TextStyle) -> CGFloat {
        #if canImport(UIKit)
        let platform: UIFont.TextStyle = switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
        return UIFont.preferredFont(forTextStyle: platform).pointSize
        #else
        let platform: NSFont.TextStyle = switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
        return NSFont.preferredFont(forTextStyle: platform).pointSize
        #endif
    }
}
