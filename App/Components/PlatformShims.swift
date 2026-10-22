import SwiftUI

#if os(macOS)
// Mac stand-ins for iOS-only text field and navigation bar modifiers, so views shared with the iPhone compile on the
// Mac unchanged. On the Mac they do nothing: there is no on-screen keyboard, no autocapitalization and no
// navigation bar title mode.

enum UIKeyboardType {
    case `default`, URL, numberPad, emailAddress
}

enum TextInputAutocapitalization {
    case never, words, sentences, characters
}

enum NavigationBarTitleDisplayMode {
    case automatic, inline, large
}

extension View {
    func keyboardType(_ type: UIKeyboardType) -> some View { self }

    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View { self }

    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayMode) -> some View { self }
}
#endif
