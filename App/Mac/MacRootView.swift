import CoreSpotlight
import DoveAppCore
import DoveKit
import SwiftUI

/// The main window: a sidebar of places (search, the library by kind, downloads, the services) and the selected one.
/// The pages themselves come with phase 2 (`docs/macos.md`); the services already show their state.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    @Environment(\.openSettings) private var openSettings
    /// The sidebar starts hidden: the start page has the search field and the library's shelves.
    @State private var columns = NavigationSplitViewVisibility.detailOnly
    @State private var setupPresented = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: sidebarSelection) {
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
                    // The tag goes last: a modifier after it (the badge) hides it from the list's selection.
                    Label("Downloads", systemImage: "arrow.down.circle")
                        .badge(model.downloads.records.filter { $0.state == .downloading }.count)
                        .tag(SidebarItem.downloads)
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
                .safeAreaInset(edge: .bottom, spacing: 0) { MacNowPlayingBar() }
        }
        .onAppear {
            setupPresented = SetupState.shouldPresentAutomatically(
                finished: model.setupFinished, hasAnythingConfigured: model.hasAnythingConfigured
            )
        }
        .task { await model.updates.checkAutomatically() }
        .sheet(isPresented: $setupPresented) {
            SetupWizard()
                .frame(width: 640, height: 560)
        }
        .overlay {
            if router.isQuickSearchPresented { QuickSearchPanel() }
        }
        .animation(.easeOut(duration: 0.15), value: router.isQuickSearchPresented)
        .onChange(of: router.settingsRequested) {
            guard router.settingsRequested else { return }
            router.settingsRequested = false
            openSettings()
        }
        .onOpenURL { model.open($0) }
        .onChange(of: router.libraryPath.count) { router.syncHistory() }
        .onChange(of: router.searchPath.count) { router.syncHistory() }
        // A Spotlight result for a library title, book or watchlist entry, or a title looked at before.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String { SpotlightIndex.open(id, using: model) }
        }
        .onContinueUserActivity(SpotlightIndex.viewActivity) { SpotlightIndex.open($0, using: model) }
        // "Search in Dove" under Spotlight's Search in Apps: search for whatever was typed there.
        .onContinueUserActivity(CSQueryContinuationActionType) { activity in
            model.show(.search(activity.userInfo?[CSSearchQueryString] as? String))
        }
        // Space plays or pauses the audio player; Downloads and text fields take it first.
        .onKeyPress(.space) {
            guard model.audiobook.session != nil else { return .ignored }
            model.audiobook.togglePlayPause()
            return .handled
        }
        .dropDestination(for: URL.self) { urls, _ in
            MacSourceIntake.add(urls: urls, using: model)
        }
        .dropDestination(for: String.self) { texts, _ in
            MacSourceIntake.add(text: texts.joined(separator: "\n"), using: model)
        }
        .sheet(item: Binding(get: { model.openedSource }, set: { model.openedSource = $0 })) { batch in
            MacAddSourceSheet(sources: batch.sources) { result in
                model.openedSource = nil
                if !result.isEmpty { router.notice = result }
            }
        }
        .alert(router.notice ?? "", isPresented: Binding(get: { router.notice != nil }, set: { if !$0 { router.notice = nil } })) {
            Button("OK") {}
        }
        .alert(updateAlertTitle, isPresented: updateAlertPresented) {
            if let update = model.updates.available {
                Button("Download") { Task { await model.updates.download(update) } }
                Button("Skip This Version") { model.updates.skip(update) }
                Button("Later", role: .cancel) { model.updates.dismiss() }
            } else {
                Button("OK", role: .cancel) { model.updates.dismissManualResult() }
            }
        } message: {
            Text(updateAlertMessage)
        }
    }

    private var updateAlertPresented: Binding<Bool> {
        Binding(
            get: { model.updates.available != nil || model.updates.isUpToDate || model.updates.lastError != nil },
            set: { if !$0 { model.updates.dismissAlert() } }
        )
    }

    private var updateAlertTitle: String {
        if let update = model.updates.available { return "Dove \(update.version) is available" }
        if model.updates.lastError != nil { return "Couldn’t Check for Updates" }
        return "Dove is up to date"
    }

    private var updateAlertMessage: String {
        if let update = model.updates.available { return String(update.notes.prefix(400)) }
        return model.updates.lastError ?? "You’re running the latest version of Dove."
    }

    @ViewBuilder
    private var detail: some View {
        switch router.selection {
        case .service(let backend):
            MacLibraryStack(category: nil, service: backend).id(backend)
        case .library(let category):
            MacLibraryStack(category: category)
        case .search:
            MacSearchView()
        case .downloads:
            MacDownloadsView()
        case .onServices:
            MacOnServicesView()
        case .watchlist:
            MacWatchlistView()
        case .some(let item):
            ContentUnavailableView(item.title, systemImage: item.symbol,
                                   description: Text("This page comes with the next step of the Mac app."))
        case nil:
            ContentUnavailableView("Dove", systemImage: "bird", description: Text("Pick a place in the sidebar."))
        }
    }

    /// A click in the sidebar: the page changes and the Library goes back to its root (`MacRouter.select`).
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { router.selection }, set: { router.select($0) })
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
