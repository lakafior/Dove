import SwiftUI

/// A Settings-style row: a coloured icon, the name, and its state on the right.
struct SettingsRow: View {
    let title: String
    let symbol: String
    let color: Color
    var value: String?
    /// A status light before the value (services).
    var light: Color?

    init(_ title: String, symbol: String, color: Color, value: String? = nil, light: Color? = nil) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.value = value
        self.light = light
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if let light { StatusLight(color: light) }
                if let value { Text(value).lineLimit(1) }
            }
        } label: {
            Label {
                Text(title)
            } icon: {
                SettingsIcon(symbol: symbol, color: color)
            }
        }
    }
}
