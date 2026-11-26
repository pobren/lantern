// Languages: every phrase the apps show is looked up in Localizable.xcstrings (Shared), translated into 40 languages.
//
// SwiftUI translates a phrase written straight into Text("..."), Label("...", systemImage:) and so on. Much of our
// wording reaches the screen through a String instead (a row's title, an error, a page name), and SwiftUI shows a
// String as it is. These overloads look a String up in the catalog too, so those get translated as well. A String
// with no entry (an email's subject, a folder name of the person's own) shows unchanged, as before.
// Phrases built with \(...) that aren't shown through SwiftUI are wrapped in String(localized:) where they're made.
// The lookup gives plain text (no Markdown, no % formatting), so a subject such as "50% off *today*" shows as sent.
// The overloads are disfavoured, like SwiftUI's own String ones, so a phrase written in quotes still goes to SwiftUI's
// LocalizedStringKey version (which keeps \(...) values as placeholders) and only a String variable comes here.

import SwiftUI

extension Text {
    @_disfavoredOverload init(_ string: String) { self.init(verbatim: string.localised) }
}

extension Label where Title == Text, Icon == Image {
    @_disfavoredOverload init(_ title: String, systemImage: String) {
        self.init { Text(verbatim: title.localised) } icon: { Image(systemName: systemImage) }
    }
}

extension Button where Label == Text {
    @_disfavoredOverload init(_ title: String, action: @escaping () -> Void) {
        self.init(action: action) { Text(verbatim: title.localised) }
    }
    @_disfavoredOverload init(_ title: String, role: ButtonRole?, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(verbatim: title.localised) }
    }
}

extension Toggle where Label == Text {
    @_disfavoredOverload init(_ title: String, isOn: Binding<Bool>) {
        self.init(isOn: isOn) { Text(verbatim: title.localised) }
    }
}

extension TextField where Label == Text {
    @_disfavoredOverload init(_ title: String, text: Binding<String>) {
        self.init(text: text, prompt: Text(verbatim: title.localised)) { Text(verbatim: title.localised) }
    }
}

extension View {
    @_disfavoredOverload func navigationTitle(_ title: String) -> some View { navigationTitle(Text(verbatim: title.localised)) }
}

extension String {
    /// The catalog's translation of a String made at run time (a page name, a setting's label), or the String itself.
    var localised: String { Bundle.main.localizedString(forKey: self, value: self, table: "Localizable") }
}
