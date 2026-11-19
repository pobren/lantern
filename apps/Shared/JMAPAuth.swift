// How JMAP Connect signs in to a mail server. Fastmail uses an API token (sent as Bearer). Most other JMAP servers
// (Stalwart, Mailbux, Thundermail, Cyrus) use an email address and an app password (sent as Basic). Both are kept
// as one secret string in the Keychain; a Basic one starts "basic:", so tokens saved by earlier builds still work.

import Foundation

enum JMAPAuth {
    static let basicPrefix = "basic:"

    /// The secret to keep for an email address and app password.
    static func basic(user: String, password: String) -> String {
        basicPrefix + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    /// The Authorization header for a kept secret.
    static func header(_ secret: String) -> String {
        secret.hasPrefix(basicPrefix) ? "Basic " + secret.dropFirst(basicPrefix.count) : "Bearer " + secret
    }

    /// Makes a session address absolute. Done on the text, not with URL, because the templates hold {braces}.
    static func resolve(_ address: String, against base: URL) -> String {
        if address.lowercased().hasPrefix("http://") || address.lowercased().hasPrefix("https://") { return address }
        guard let scheme = base.scheme, let host = base.host else { return address }
        let origin = "\(scheme)://\(host)" + (base.port.map { ":\($0)" } ?? "")
        if address.hasPrefix("/") { return origin + address }
        var folder = base.path
        if let slash = folder.lastIndex(of: "/") { folder = String(folder[...slash]) } else { folder = "/" }
        return origin + folder + address
    }
}
