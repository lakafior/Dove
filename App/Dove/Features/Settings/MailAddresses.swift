import DoveKit

/// The addresses typed on Settings › Reading, empty for a target not typed yet, so a text field binds to each.
struct MailAddresses {
    private var values: [ReadingTarget: String] = [:]

    subscript(target: ReadingTarget) -> String {
        get { values[target] ?? "" }
        set { values[target] = newValue }
    }
}
