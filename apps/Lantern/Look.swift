// Lantern's look in one place: colours and the small pieces every screen shares.
// Clean and quiet: system fonts, one blue accent, and a colour per account so mixed lists stay clear.

import SwiftUI
import CryptoKit
#if os(iOS)
import UIKit
#endif

enum Look {
    static let accent = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xD3 / 255)
    static let fastmail = Color(red: 0x2F / 255, green: 0x5B / 255, blue: 0xD3 / 255)
    static let mailApp = Color(red: 0xD9 / 255, green: 0x82 / 255, blue: 0x2B / 255)
    static let other = Color(red: 0x2E / 255, green: 0x9E / 255, blue: 0x5B / 255)
    static let star = Color(red: 0xE8 / 255, green: 0xA3 / 255, blue: 0x17 / 255)

    /// Text a little larger than the bare point sizes, more so on iPhone and iPad where it's read at arm's length.
    #if os(macOS)
    static let scale: CGFloat = 1.08
    static let bodyPoints = 15
    #else
    static let scale: CGFloat = 1.15
    static let bodyPoints = 17
    #endif
    static func size(_ points: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: (points * scale).rounded(), weight: weight)
    }

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

/// The person's initials on their colour, or their Gravatar picture when they have one and it's switched on.
struct Avatar: View {
    let address: EmailAddress
    var size: CGFloat = 34
    @AppStorage(Gravatar.key) private var gravatar = true
    @State private var face: Image?

    var body: some View {
        let email = address.email.lowercased()
        let (bg, fg) = Look.tint(for: email)
        ZStack {
            Text(address.initials)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: size, height: size)
                .background(Circle().fill(bg))
            if gravatar, let shown = face ?? Gravatar.cached(email) {
                shown.resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: gravatar ? email : "") {
            face = gravatar && !email.isEmpty ? await Gravatar.load(email) : nil
        }
    }
}

/// Pictures people set up at gravatar.com. Lantern asks with a scrambled (hashed) copy of the address, never the
/// address itself, and remembers who has no picture so it doesn't ask again.
enum Gravatar {
    static let key = "gravatar"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var found: [String: Image] = [:]
    nonisolated(unsafe) private static var none: Set<String> = []

    static func cached(_ email: String) -> Image? {
        lock.lock(); defer { lock.unlock() }
        return found[email]
    }

    static func load(_ email: String) async -> Image? {
        lock.lock()
        if let hit = found[email] { lock.unlock(); return hit }
        if none.contains(email) { lock.unlock(); return nil }
        lock.unlock()
        let hash = SHA256.hash(data: Data(email.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "https://gravatar.com/avatar/\(hash)?s=160&d=404"),
              let answer = try? await URLSession.shared.data(from: url) else { return nil }
        let (data, response) = answer
        var image: Image?
        if (response as? HTTPURLResponse)?.statusCode == 200 {
            #if os(macOS)
            if let picture = NSImage(data: data) { image = Image(nsImage: picture) }
            #else
            if let picture = UIImage(data: data) { image = Image(uiImage: picture) }
            #endif
        }
        lock.lock()
        if let image { found[email] = image } else { none.insert(email) }
        lock.unlock()
        return image
    }
}

struct AccountDot: View {
    let account: Account
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(account.colour).frame(width: size, height: size).accessibilityLabel(account.label)
    }
}

/// On the Mac, sheets have no title bar, so they looked bare. This gives each one the same header as the
/// Settings pages: a large coloured icon, its name and a line on what it's for. On iPhone and iPad the
/// navigation title already does this job, so nothing changes there.
struct SheetHeader: ViewModifier {
    let title: String
    let icon: String
    let tint: Color
    let blurb: String

    func body(content: Content) -> some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.gradient))
                    .shadow(color: tint.opacity(0.3), radius: 6, y: 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 2)
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func sheetHeader(_ title: String, icon: String, tint: Color, blurb: String) -> some View {
        modifier(SheetHeader(title: title, icon: icon, tint: tint, blurb: blurb))
    }
}

/// Links to the JMAP Connect community on jmapconnect.app. Bug reports arrive with the app version, device and
/// system already filled in, so people don't have to look them up.
enum Community {
    enum Kind: String { case bug, idea }

    static let home = URL(string: "https://jmapconnect.app/community/")!

    static func new(_ kind: Kind) -> URL {
        let info = Bundle.main.infoDictionary
        let app = "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
        var c = URLComponents(string: "https://jmapconnect.app/community/new/")!
        c.queryItems = [URLQueryItem(name: "kind", value: kind.rawValue), URLQueryItem(name: "app", value: app),
                        URLQueryItem(name: "device", value: device), URLQueryItem(name: "os", value: system)]
        return c.url ?? home
    }

    private static var device: String {
        var s = utsname()
        uname(&s)
        let id = withUnsafeBytes(of: &s.machine) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        #if os(macOS)
        return "Mac (\(id))"
        #else
        return id   // such as iPhone17,1
        #endif
    }

    private static var system: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let name = "macOS"
        #else
        let name = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        return "\(name) \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }
}
