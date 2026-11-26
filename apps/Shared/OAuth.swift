// Sign in with Fastmail (Paul, 20 Nov 2026): OAuth 2.0 with PKCE instead of pasting an API token.
//
// Fastmail lets native apps sign in without registering with them first: the client id is the address of a small
// JSON file we publish (an "OAuth Client ID Metadata Document"), which names the app, its icon and where Fastmail
// may send people back to. See https://www.fastmail.com/dev/ ("OAuth at Fastmail").
//
// What we keep, per account, in the Keychain group shared with the notification extension (never iCloud: Fastmail
// says each device must get its own sign in, and a refresh token used twice is revoked):
//   an access token (short lived), a refresh token (replaced every time it's used), and when the access token ends.
// The account's own secret in the app's Keychain is just "oauth:<key id>", pointing at that record. So everything
// that held an API token (the app, instant alerts, the extension) works the same, asking for a fresh header first.
//
// Two processes (the app and the notification extension) can need a new access token at the same moment. Using the
// same refresh token twice would sign the person out, so a refresh holds a Keychain lock (adding an item is atomic).

import Foundation
import Security
import CryptoKit

enum FastmailOAuth {
    static let issuer = "https://api.fastmail.com"
    static let authorize = URL(string: "https://api.fastmail.com/oauth/authorize")!
    static let tokenURL = URL(string: "https://api.fastmail.com/oauth/refresh")!
    /// The resource the tokens are for (RFC 8707). Fastmail lists its protected resources in its server metadata and
    /// refuses a code swap without one ("invalid_target", Paul's test 20 Nov), so every request names the JMAP session.
    static let resource = "https://api.fastmail.com/jmap/session"
    static let revokeURL = URL(string: "https://api.fastmail.com/oauth/revoke")!
    static let sessionURL = "https://api.fastmail.com/jmap/session"
    /// Fastmail's calendar server. Calendars aren't open over JMAP yet, so the calendar talks CalDAV, with an access
    /// token for this resource from the same sign in (a refresh naming it, RFC 8707). Tested on Paul's account 26 Nov 2026.
    static let caldav = "https://caldav.fastmail.com"
    static let calendarsScope = "urn:ietf:params:oauth:scope:calendars"

    /// Our client id: the address of the metadata file on jmapconnect.app (paulobrien-site jmapconnect-site/public/oauth/).
    /// A build can point elsewhere with JCOAuthClient in Info.plist, for testing before the file is live.
    static var clientId: String {
        (Bundle.main.object(forInfoDictionaryKey: "JCOAuthClient") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "https://jmapconnect.app/oauth/client.json"
    }

    /// Private-use scheme from our domain reversed, with Fastmail in the path so another provider never shares it.
    static let callbackScheme = "app.jmapconnect"
    static let redirectURI = "app.jmapconnect:/oauth/fastmail"

    /// Mail, contacts and (from 1.3) calendars. Apps that sign in without registering (as we do) use the general mail scopes from the
    /// OAuth profile for open public clients, which Fastmail lists in its server metadata; the JMAP-only scopes are
    /// for registered apps (asking for them gave "this request is invalid", Paul's test 20 Nov 2026).
    /// Mail covers reading, sending and out of office. offline_access gives the refresh token.
    static let scopes = [
        "urn:ietf:params:oauth:scope:mail",
        "urn:ietf:params:oauth:scope:contacts",
        "urn:ietf:params:oauth:scope:calendars",
        "offline_access",
    ]

    static let prefix = "oauth:"
    static func isOAuth(_ secret: String) -> Bool { secret.hasPrefix(prefix) }
    static func keyId(_ secret: String) -> String { String(secret.dropFirst(prefix.count)) }

    // MARK: Starting a sign in

    struct Request {
        let url: URL
        let state: String
        let verifier: String
    }

    static func start() -> Request {
        let verifier = random(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = random(24)
        var c = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "resource", value: resource),
        ]
        return Request(url: c.url!, state: state, verifier: verifier)
    }

    enum Failure: LocalizedError {
        case cancelled, refused(String), mixUp, signedOut(String?)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Sign in was cancelled."
            case .refused(let why): return "Fastmail didn't sign you in (\(why)). Try again, or use an API token instead."
            case .mixUp: return "That sign in didn't come back from Fastmail as expected, so it wasn't used. Please try again."
            case .signedOut(let why): return why ?? "Fastmail signed this account out. Sign in again to carry on."
            }
        }
    }

    /// Checks what came back on our redirect address, then swaps the code for tokens and keeps them.
    /// Returns the secret to keep for the account ("oauth:<key id>").
    /// With `into`, the tokens replace an existing sign in's (turning on calendar for someone who signed in before 1.3).
    static func finish(_ callback: URL, request: Request, into existing: String? = nil) async throws -> String {
        guard callback.scheme == callbackScheme, callback.path == "/oauth/fastmail" else { throw Failure.mixUp }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == request.state else { throw Failure.mixUp }
        if let iss = value("iss"), iss != issuer { throw Failure.mixUp }
        if let error = value("error") { throw error == "access_denied" ? Failure.cancelled : Failure.refused(error) }
        guard let code = value("code") else { throw Failure.mixUp }
        let tokens = try await post([
            "client_id": clientId, "redirect_uri": redirectURI, "grant_type": "authorization_code",
            "code": code, "code_verifier": request.verifier, "resource": resource,
        ])
        let key = existing.map(keyId) ?? UUID().uuidString
        if existing != nil, let old = OAuthStore.read(key) {
            // The old sign in is finished with: tell Fastmail, then keep the new one under the same key.
            var r = URLRequest(url: revokeURL)
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = form(["client_id": clientId, "token": old.refresh, "token_type_hint": "refresh_token"])
            _ = try? await URLSession.shared.data(for: r)
        }
        OAuthStore.save(key, tokens)
        return prefix + key
    }

    // MARK: Keeping the access token fresh

    /// The Authorization header for a secret, refreshing a Fastmail sign in first when its access token is about to end.
    /// API tokens and app passwords are returned as they are. `force` refreshes even if the token looks fine (after a 401).
    static func header(_ secret: String, force: Bool = false) async throws -> String {
        guard isOAuth(secret) else { return JMAPAuth.header(secret) }
        return "Bearer " + (try await accessToken(keyId(secret), force: force))
    }

    static func accessToken(_ key: String, force: Bool = false) async throws -> String {
        guard var t = OAuthStore.read(key) else { throw Failure.signedOut(nil) }
        if t.signedOut { throw Failure.signedOut(t.problem) }
        if !force && t.expires.timeIntervalSinceNow > 90 { return t.access }
        let seen = t.access

        guard await OAuthStore.lock(key) else {
            // Someone else held the lock for too long: use whatever they left, if it's newer.
            if let now = OAuthStore.read(key), now.access != seen, now.expires.timeIntervalSinceNow > 30 { return now.access }
            throw Failure.signedOut(nil)
        }
        defer { OAuthStore.unlock(key) }
        // While we waited, the app or the extension may already have refreshed it.
        if let now = OAuthStore.read(key) { t = now }
        if t.signedOut { throw Failure.signedOut(t.problem) }
        if t.access != seen && t.expires.timeIntervalSinceNow > 30 { return t.access }

        do {
            var fresh = try await post(["client_id": clientId, "grant_type": "refresh_token", "refresh_token": t.refresh, "resource": resource])
            fresh.calendarAccess = t.calendarAccess
            fresh.calendarExpires = t.calendarExpires
            OAuthStore.save(key, fresh)
            NotificationCenter.default.post(name: refreshed, object: key)
            return fresh.access
        } catch TokenError.grant(let temporary, let description) where !temporary {
            t.signedOut = true
            t.problem = description
            OAuthStore.save(key, t)
            throw Failure.signedOut(description)
        }
    }

    /// Whether a sign in includes calendars (sign ins from before 1.3 don't, and need approving once more).
    static func allowsCalendars(_ secret: String) -> Bool {
        guard isOAuth(secret), let t = OAuthStore.read(keyId(secret)) else { return false }
        return !t.scope.isEmpty && t.allows(calendarsScope)
    }

    /// The Authorization header for Fastmail's calendar server. Same refresh token and lock as mail: the refresh names
    /// the calendar server, and the new refresh token it gives replaces the old one for both.
    static func calendarHeader(_ secret: String, force: Bool = false) async throws -> String {
        guard isOAuth(secret) else { return JMAPAuth.header(secret) }
        let key = keyId(secret)
        guard var t = OAuthStore.read(key) else { throw Failure.signedOut(nil) }
        if t.signedOut { throw Failure.signedOut(t.problem) }
        if !force, let a = t.calendarAccess, let e = t.calendarExpires, e.timeIntervalSinceNow > 90 { return "Bearer " + a }
        let seen = t.calendarAccess
        guard await OAuthStore.lock(key) else { throw Failure.signedOut(nil) }
        defer { OAuthStore.unlock(key) }
        if let now = OAuthStore.read(key) { t = now }
        if t.signedOut { throw Failure.signedOut(t.problem) }
        if let a = t.calendarAccess, a != seen, let e = t.calendarExpires, e.timeIntervalSinceNow > 30 { return "Bearer " + a }
        do {
            let fresh = try await post(["client_id": clientId, "grant_type": "refresh_token", "refresh_token": t.refresh, "resource": caldav])
            t.refresh = fresh.refresh
            t.calendarAccess = fresh.access
            t.calendarExpires = fresh.expires
            OAuthStore.save(key, t)
            return "Bearer " + fresh.access
        } catch TokenError.grant(let temporary, let description) where !temporary {
            t.signedOut = true
            t.problem = description
            OAuthStore.save(key, t)
            throw Failure.signedOut(description)
        }
    }

    /// Posted (with the key id) whenever a new access token is saved, so the Watch can be given it.
    static let refreshed = Notification.Name("JCOAuthRefreshed")

    /// Tells Fastmail we're done with this sign in (when the account is removed), and forgets the tokens.
    static func signOut(_ secret: String) async {
        guard isOAuth(secret) else { return }
        let key = keyId(secret)
        if let t = OAuthStore.read(key) {
            var r = URLRequest(url: revokeURL)
            r.httpMethod = "POST"
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = form(["client_id": clientId, "token": t.refresh, "token_type_hint": "refresh_token"])
            _ = try? await URLSession.shared.data(for: r)
        }
        OAuthStore.delete(key)
    }

    // MARK: Talking to the token endpoint

    enum TokenError: Error { case grant(temporary: Bool, description: String?), http(Int) }

    private static func post(_ fields: [String: String]) async throws -> OAuthTokens {
        var r = URLRequest(url: tokenURL)
        r.httpMethod = "POST"
        r.timeoutInterval = 30
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = form(fields)
        let (data, response) = try await URLSession.shared.data(for: r)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard code == 200, let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            if json["error"] as? String == "invalid_grant" {
                throw TokenError.grant(temporary: json["temporary"] as? Bool ?? false, description: json["error_description"] as? String)
            }
            if let e = json["error"] as? String { throw Failure.refused(e) }
            throw TokenError.http(code)
        }
        let life = (json["expires_in"] as? Double) ?? Double(json["expires_in"] as? Int ?? 3600)
        return OAuthTokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(life),
                           scope: json["scope"] as? String ?? "")
    }

    private static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").utf8)
    }

    private static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }
}

struct OAuthTokens: Codable {
    var access: String
    var refresh: String
    var expires: Date
    var scope: String
    var signedOut = false
    var problem: String?
    /// A separate access token for the calendar server (CalDAV), from the same refresh token.
    var calendarAccess: String?
    var calendarExpires: Date?

    /// Whether this sign in includes a scope (Fastmail may give fewer than were asked for).
    func allows(_ scope: String) -> Bool { self.scope.isEmpty || self.scope.split(separator: " ").contains { $0 == scope } }
}

/// Fastmail sign ins, in the Keychain group shared with the notification extension (this device only).
enum OAuthStore {
    private static let service = "dev.paulobrien.lantern.oauth"
    private static let lockService = "dev.paulobrien.lantern.oauth.lock"
    static var group: String? { Bundle.main.object(forInfoDictionaryKey: "JCKeychainGroup") as? String }

    private static func base(_ service: String, _ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        // The Mac has no notification extension to share with (and no group in its entitlements).
        #if os(iOS)
        if let group { q[kSecAttrAccessGroup as String] = group }
        #else
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }

    static func save(_ key: String, _ t: OAuthTokens) {
        guard let data = try? JSONEncoder().encode(t) else { return }
        if SecItemUpdate(base(service, key) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return }
        var q = base(service, key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(_ key: String) -> OAuthTokens? {
        var q = base(service, key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    static func delete(_ key: String) {
        SecItemDelete(base(service, key) as CFDictionary)
        SecItemDelete(base(lockService, key) as CFDictionary)
    }

    /// Takes the refresh lock for a sign in, waiting up to 20 seconds. A lock older than 45 seconds was left by a
    /// process that stopped part way (the extension has 30 seconds), so it's cleared.
    static func lock(_ key: String) async -> Bool {
        for _ in 0..<80 {
            var q = base(lockService, key)
            q[kSecValueData as String] = Data(String(Date().timeIntervalSince1970).utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(q as CFDictionary, nil)
            if status == errSecSuccess { return true }
            if status != errSecDuplicateItem { return false }
            var r = base(lockService, key)
            r[kSecReturnData as String] = true
            var out: AnyObject?
            if SecItemCopyMatching(r as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
               let when = Double(String(decoding: d, as: UTF8.self)), Date().timeIntervalSince1970 - when > 45 {
                SecItemDelete(base(lockService, key) as CFDictionary)
                continue
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    static func unlock(_ key: String) {
        SecItemDelete(base(lockService, key) as CFDictionary)
    }
}
