import SwiftUI

/// Settings › About: the version, who makes Dove, where its code, site and policies are, and the licences of what
/// it ships. Shared by the iPhone and the Mac (links only, no UIKit).
struct AboutView: View {
    static let repository = URL(string: "https://github.com/lakafior/Dove")!
    static let website = URL(string: "https://dove.smigi.net")!
    static let privacy = URL(string: "https://dove.smigi.net/privacy")!
    static let support = URL(string: "https://dove.smigi.net/support")!
    static let issues = URL(string: "https://github.com/lakafior/Dove/issues")!
    static let author = URL(string: "https://github.com/lakafior")!
    static let license = URL(string: "https://mozilla.org/MPL/2.0/")!
    static let mail = URL(string: "mailto:dove@smigi.net")!

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    Image(systemName: "bird.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Dove").font(.title2.bold())
                    Text("Version \(SettingsCatalog.version)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                LabeledContent("Author") {
                    Link("Smigi", destination: Self.author)
                }
                Link(destination: Self.website) { row("Website", detail: "dove.smigi.net", symbol: "globe") }
                Link(destination: Self.repository) { row("Source code", detail: "GitHub", symbol: "chevron.left.forwardslash.chevron.right") }
            }

            Section {
                Link(destination: Self.privacy) { row("Privacy policy", symbol: "hand.raised") }
                Link(destination: Self.support) { row("Support and FAQ", symbol: "questionmark.circle") }
                Link(destination: Self.issues) { row("Report a problem", symbol: "exclamationmark.bubble") }
                Link(destination: Self.mail) { row("E-mail", detail: "dove@smigi.net", symbol: "envelope") }
            } footer: {
                Text("Dove has no account and no server of its own: keys stay in your Keychain and go only to the services they belong to.")
            }

            Section {
                Link(destination: Self.license) { row("Mozilla Public License 2.0", symbol: "doc.text") }
                if AcknowledgementsView.text != nil {
                    NavigationLink("Acknowledgements") { AcknowledgementsView() }
                }
            } header: {
                Text("License")
            } footer: {
                Text("Dove is free software: you may use, study, change and share it under the MPL 2.0.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, detail: String? = nil, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(.primary)
            Spacer()
            if let detail { Text(detail).foregroundStyle(.secondary) }
            Image(systemName: "arrow.up.forward").font(.footnote).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// Licences of the third-party code Dove ships (the iPhone's ebook reader: epub.js and JSZip), as bundled in
/// `THIRD-PARTY-NOTICES.txt`. The Mac has no reader, so no notices and no row.
struct AcknowledgementsView: View {
    static var text: String? {
        Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    var body: some View {
        ScrollView {
            Text(Self.text ?? "")
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
