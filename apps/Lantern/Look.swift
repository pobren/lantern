// Lantern's look in one place: colours, type and the small pieces every screen shares.
// Calm and light by default, one blue accent, Fastmail blue and Mail App orange to tell accounts apart.

import SwiftUI

enum Look {
    static let accent = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xD3 / 255)
    static let accentSoft = Color(red: 0xE6 / 255, green: 0xEC / 255, blue: 0xFB / 255)
    static let ink = Color(red: 0x16 / 255, green: 0x19 / 255, blue: 0x1D / 255)
    static let muted = Color(red: 0x5B / 255, green: 0x65 / 255, blue: 0x70 / 255)
    static let ground = Color(red: 0xF4 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    static let line = Color(red: 0xE3 / 255, green: 0xE6 / 255, blue: 0xEB / 255)
    static let fastmail = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xD3 / 255)
    static let mailApp = Color(red: 0xD9 / 255, green: 0x82 / 255, blue: 0x2B / 255)
    static let other = Color(red: 0x2E / 255, green: 0x9E / 255, blue: 0x5B / 255)

    // Focus mode is dark on purpose: one card under a lamp.
    static let night = Color(red: 0x0E / 255, green: 0x10 / 255, blue: 0x14 / 255)
    static let nightCard = Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x23 / 255)
    static let nightRaised = Color(red: 0x22 / 255, green: 0x26 / 255, blue: 0x2E / 255)
    static let nightInk = Color(red: 0xF2 / 255, green: 0xF3 / 255, blue: 0xF5 / 255)
    static let nightMuted = Color(red: 0xA3 / 255, green: 0xAA / 255, blue: 0xB5 / 255)
    static let nightAccent = Color(red: 0x7E / 255, green: 0xA2 / 255, blue: 0xFF / 255)

    /// Big headings use the system serif for warmth; everything else is the system font.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }

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
            .font(.system(size: size * 0.36, weight: .bold))
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

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Look.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

/// The small rounded buttons on cards: one dark main action, the rest outlined.
struct PillButton: View {
    let title: String
    let icon: String
    var primary = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: primary ? .semibold : .regular))
                .padding(.horizontal, 12).frame(height: 30)
                .foregroundStyle(primary ? Color.white : Look.ink)
                .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Look.ink : Color.white))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? Color.clear : Look.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
