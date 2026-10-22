import DoveAppCore
import DoveKit
import SwiftUI

/// The main window: a sidebar of places (search, the library by kind, downloads, the services) and the selected one.
/// The pages themselves come with phase 2 (`docs/macos.md`); the services already show their state.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            List(selection: $router.selection) {
                Section {
                    Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
                    Label("Watchlist", systemImage: "bookmark").tag(SidebarItem.watchlist)
                }
                Section("Library") {
                    Label("All", systemImage: "books.vertical").tag(SidebarItem.library(nil))
                    ForEach(libraryCategories, id: \.self) { category in
                        Label(category.title, systemImage: category.symbol).tag(SidebarItem.library(category))
                    }
                }
                Section("Activity") {
                    Label("Downloads", systemImage: "arrow.down.circle").tag(SidebarItem.downloads)
                        .badge(model.downloads.records.filter { $0.state == .downloading }.count)
                    Label("On services", systemImage: "icloud.and.arrow.down").tag(SidebarItem.onServices)
                }
                if !services.isEmpty {
                    Section("Services") {
                        ForEach(services, id: \.self) { backend in
                            ServiceSidebarRow(backend: backend).tag(SidebarItem.service(backend))
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            detail
        }
        .onChange(of: router.settingsRequested) {
            guard router.settingsRequested else { return }
            router.settingsRequested = false
            openSettings()
        }
        .onOpenURL { model.open($0) }
    }

    @ViewBuilder
    private var detail: some View {
        switch router.selection {
        case .service(let backend):
            ServiceStatusPage(backend: backend)
        case .library(let category):
            MacLibraryView(category: category)
        case .some(let item):
            ContentUnavailableView(item.title, systemImage: item.symbol,
                                   description: Text("This page comes with the next step of the Mac app."))
        case nil:
            ContentUnavailableView("Dove", systemImage: "bird", description: Text("Pick a place in the sidebar."))
        }
    }

    /// The kinds the library holds (adult only when shown), like the iPhone's Library chips.
    private var libraryCategories: [LibraryFilter.Category] {
        let items = model.library.items
        return LibraryFilter.Category.allCases.filter { category in
            (category != .adult || model.showAdult) && items.contains { category.contains($0) }
        }
    }

    /// Services and places that are set up, in Settings' order.
    private var services: [BackendID] {
        (BackendID.services + [.calibre, .iCloudDrive]).filter(model.isConfigured)
    }
}

/// A service in the sidebar: its name and status light.
private struct ServiceSidebarRow: View {
    @Environment(AppModel.self) private var model
    let backend: BackendID

    var body: some View {
        HStack {
            Label(backend.displayName, systemImage: backend.settingsSymbol)
            Spacer()
            StatusLight(color: model.services.light(backend))
        }
    }
}

/// A service's state: whether the last refresh reached it, and its plan or premium days.
private struct ServiceStatusPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let backend: BackendID

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        StatusLight(color: model.services.light(backend))
                        Text(status)
                    }
                }
                if let account = model.services.accountSummary(backend) {
                    LabeledContent("Account", value: account)
                }
                LabeledContent("Items", value: "\(model.library.items.filter { $0.item.backend == backend }.count)")
            }
            Section {
                Button("Open Settings…") { openSettings() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(backend.displayName)
    }

    private var status: String {
        if case .offline = model.services.health(of: backend) { return "Offline" }
        return model.library.updatedAt == nil ? "Not checked yet" : "Online"
    }
}

private extension SidebarItem {
    var title: String {
        switch self {
        case .search: "Search"
        case .library(let category): category?.title ?? "Library"
        case .downloads: "Downloads"
        case .onServices: "On services"
        case .watchlist: "Watchlist"
        case .service(let backend): backend.displayName
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .library(let category): category?.symbol ?? "books.vertical"
        case .downloads: "arrow.down.circle"
        case .onServices: "icloud.and.arrow.down"
        case .watchlist: "bookmark"
        case .service(let backend): backend.settingsSymbol
        }
    }
}

extension LibraryFilter.Category {
    /// Sidebar symbols, the same family as the Library's shelf tiles on iOS.
    var symbol: String {
        switch self {
        case .movies: "film"
        case .series: "tv"
        case .music: "music.note"
        case .books: "book.closed"
        case .audiobooks: "headphones"
        case .games: "gamecontroller"
        case .software: "app.badge"
        case .adult: "eye.slash"
        case .other: "doc"
        }
    }
}
