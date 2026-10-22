import DoveAppCore
import DoveKit
import SwiftUI

/// The rows of a `ReleaseList` inside a `List`: Download only, filters, format chips, the releases, and what
/// is hidden (the other book kind, other books).
struct ReleaseListSection: View {
    @Environment(AppModel.self) private var model
    @Bindable var list: ReleaseList
    var title: String?
    @State private var showFilters = false

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle("Download only", isOn: $model.downloadOnly)
            Button {
                showFilters = true
            } label: {
                Label(
                    list.filter.isActive
                        ? "Showing \(list.visible.count) of \(list.groups.count) · filters on"
                        : "Filter and sort",
                    systemImage: list.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                )
            }
            if !list.formats.isEmpty { formatBar }
            if !list.musicFormats.isEmpty { musicFormatBar }
            if !list.gamePlatforms.isEmpty { gamePlatformBar }
            ForEach(list.visible) { group in
                OtherResultRow(
                    group: group,
                    isBusy: list.busy.contains(group.id),
                    downloadOnly: model.downloadOnly,
                    onAdd: list.canAdd(group, model: model) ? { list.add(group, model: model) } : nil
                )
            }
            let otherBooks = list.isForOneTitle ? list.bookSplit.other.count : 0
            if otherBooks > 0 {
                Button(list.showOtherBooks ? "Hide \(otherBooks) other results" : "Show \(otherBooks) other results") {
                    list.showOtherBooks.toggle()
                }
                .font(.subheadline)
            }
            if let toggle = otherKindToggle {
                Button(toggle) { list.showOtherBookKind.toggle() }
                    .font(.subheadline)
            }
        } header: {
            if let title { Text(title) }
        } footer: {
            if list.visible.contains(where: { !list.canAdd($0, model: model) }) {
                Text("NZBs need nzbdav or Usenet on TorBox, Offcloud or Premiumize, torrents a debrid service: set them up in Settings.")
            }
        }
        .sheet(isPresented: $showFilters) {
            SourceFilterSheet(
                filter: $list.filter,
                groups: list.groups,
                dimensions: [.type, .privacy, .provider, .tracker, .cached],
                sorts: [.addon, .seeders, .newest, .sizeDescending, .sizeAscending],
                showsAppleTV: false
            )
            .presentationDetents([.medium, .large])
        }
    }

    private var otherKindToggle: String? {
        let count = list.kindSplit.other.count
        guard count > 0 else { return nil }
        let kind = list.category == .books ? (count == 1 ? "audiobook" : "audiobooks") : (count == 1 ? "ebook" : "ebooks")
        return list.showOtherBookKind ? "Hide \(count) \(kind)" : "Show \(count) \(kind) filed here"
    }

    private var formatBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", selected: list.bookFormat == nil) { list.bookFormat = nil }
                ForEach(list.formats, id: \.self) { format in
                    chip(format.displayName, selected: list.bookFormat == format) {
                        list.bookFormat = list.bookFormat == format ? nil : format
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var musicFormatBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", selected: list.musicFormat == nil) { list.musicFormat = nil }
                ForEach(list.musicFormats, id: \.self) { format in
                    chip(format.displayName, selected: list.musicFormat == format) {
                        list.musicFormat = list.musicFormat == format ? nil : format
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var gamePlatformBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All", selected: list.gamePlatform == nil) { list.gamePlatform = nil }
                ForEach(list.gamePlatforms, id: \.self) { platform in
                    chip(platform.displayName, selected: list.gamePlatform == platform) {
                        list.gamePlatform = list.gamePlatform == platform ? nil : platform
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.subheadline)
            .buttonStyle(.bordered)
            .tint(selected ? .accentColor : .secondary)
            .buttonBorderShape(.capsule)
    }
}
