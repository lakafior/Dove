import DoveAppCore
import DoveKit
import SwiftUI

/// ⌘F on a page other than Search: the same large field floating over the page, Spotlight style. Return searches
/// (the Search page shows the results); Esc or a click outside closes it.
struct QuickSearchPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(MacRouter.self) private var router
    @AppStorage("macSearchCategory") private var category: SearchCategory = .media
    @FocusState private var isFocused: Bool
    @State private var suggestions = SearchSuggestions()

    var body: some View {
        @Bindable var router = router
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture { router.isQuickSearchPresented = false }
                .accessibilityHidden(true)
            SpotlightField(
                text: $router.searchText, category: $category,
                categories: SearchCategory.allCases.filter { $0 != .adult || model.showAdult },
                focus: $isFocused, suggestions: suggestions.items, onPick: router.open
            ) {
                router.isQuickSearchPresented = false
                router.submitSearch()
            }
            .frame(maxWidth: 680)
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .padding(.top, 120)
            .padding(.horizontal, 40)
        }
        .onAppear { isFocused = true }
        .onChange(of: router.searchText) { suggestions.update(router.searchText, category: category, model: model) }
        // Like Spotlight: Esc clears the words first, then closes.
        .onExitCommand {
            if router.searchText.isEmpty { router.isQuickSearchPresented = false } else { router.searchText = "" }
        }
        .transition(.opacity)
    }
}
