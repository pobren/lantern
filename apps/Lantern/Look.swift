// Lantern's look in one place: colours and the small pieces every screen shares.
// Clean and quiet: system fonts, one blue accent, and a colour per account so mixed lists stay clear.

import SwiftUI

enum Look {
    static let accent = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xD3 / 255)
    static let fastmail = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xD3 / 255)
    static let mailApp = Color(red: 0xD9 / 255, green: 0x82 / 255, blue: 0x2B / 255)
    static let other = Color(red: 0x2E / 255, green: 0x9E / 255, blue: 0x5B / 255)
    static let star = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x17 / 255)

    #if os(macOS)
    static let paper = Color(nsColor: .textBackgroundColor)
    static let ground = Color(nsColor: .windowBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    #else
    static let paper = Color(uiColor: .systemBackground)
    static let ground = Color(uiColor: .secondarySystemBackground)
    static let line = Color(uiColor: .separator)
    #endif

    /// A soft tint per person, so the same person always gets the same colour.
    static func tint(for key: String) -> (Color, Color) {
        let pairs: [(Color, Color)] = [
            (Color(red: 0.90, green: 0.93, blue: 0.98), Color(red: 0.12, green: 0.25, blue: 0.60)),
            (Color(red: 0.99, green: 0.92, blue: 0.87), Color(red: 0.54, green: 0.29, blue: 0.07)),
            (Color(red: 0.89, green: 0.95, blue: 0.91), Color(red: 0.12, green: 0.42, blue: 0.25)),
            (Color(red: 0.93, green: 0.91, blue: 0.98), Color(red: 0.29, green: 0.18, blue: 0.60)),
            (Color(red: 0.98, green: 0.91, blue: 0.93), Color(red: 0.56, green: 0.14, blue: 0.25)),
            (Color(red: 0.89, green: 0.95, blue: 0.96), Color(red: 0.11, green: 0.35, blue: 0.45))
        ]
        let n = key.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return pairs[n % pairs.count]
    }
}

struct Avatar: View {
    let address: EmailAddress
    var size: CGFloat = 34
    var body: some View {
        let (bg, fg) = Look.tint(for: address.email.lowercased())
        Text(address.initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(fg)
            .frame(width: size, height: size)
            .background(Circle().fill(bg))
            .accessibilityHidden(true)
    }
}

struct AccountDot: View {
    let account: Account
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(account.colour).frame(width: size, height: size).accessibilityLabel(account.label)
    }
}
