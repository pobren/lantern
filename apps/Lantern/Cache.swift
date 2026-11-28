// Mail kept on the device, so the app opens instantly, reads and searches with no connection, and remembers what
// you did offline until it can tell the server. One SQLite file (SQLite is part of every Apple device), with its
// full text search (FTS5) for searching. Nothing here leaves the device; it can always be downloaded again, so it
// stays out of iCloud backups and goes when the account is removed or you clear it in Settings.

import Foundation
import SQLite3

/// What's saved for reading one email offline.
struct SavedPage: Sendable {
    let html: String
    let text: String
    let attachments: [Attachment]
    /// True when it came from opening the email (pictures sent inside it included), not from the background fill.
    let complete: Bool
}

/// Something done while offline, waiting to go to the server.
struct Pending: Codable, Sendable {
    var n: Int64 = 0
    let account: String
    let kind: String              // "update" (read, star, move, delete) or "send"
    let data: Data                // JSON: the Email/set patches, or an OutboxEmail
}

/// An email written offline, sent as soon as there's a connection.
struct OutboxEmail: Codable, Sendable {
    let identityId: String
    let address: String?
    let to: [EmailAddress]
    let cc: [EmailAddress]
    let bcc: [EmailAddress]
    let subject: String
    let text: String
    let inReplyTo: String?
    let references: [String]
    let attachments: [OutgoingFile]
    let replacing: String?
}

/// Outgoing in a form that can be saved.
struct OutgoingFile: Codable, Sendable {
    let blobId: String
    let name: String
    let type: String
    let size: Int
}

extension Attachment: Codable {
    enum CodingKeys: String, CodingKey { case blobId, name, type, size }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(blobId: try c.decode(String.self, forKey: .blobId), name: try c.decode(String.self, forKey: .name),
                  type: try c.decode(String.self, forKey: .type), size: try c.decode(Int.self, forKey: .size))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(blobId, forKey: .blobId); try c.encode(name, forKey: .name)
        try c.encode(type, forKey: .type); try c.encode(size, forKey: .size)
    }
}

actor MailCache {
    static let shared = MailCache()

    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Where the saved mail lives: Application Support/Mail, kept out of backups and locked by the device's encryption.
    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mail", isDirectory: true)
    }

    /// Attachments you've opened, kept so they open again offline.
    nonisolated static var files: URL { folder.appendingPathComponent("Files", isDirectory: true) }

    private init() {}

    private func open() -> OpaquePointer? {
        if let db { return db }
        let fm = FileManager.default
        var dir = Self.folder
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        #if os(iOS)
        // Readable once the phone has been unlocked after a restart, so background checks still work.
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        #endif
        let path = dir.appendingPathComponent("mail.sqlite").path
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            NSLog("JCCACHE couldn't open the mail cache")
            sqlite3_close(handle)
            return nil
        }
        db = handle
        exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA foreign_keys=OFF;
        CREATE TABLE IF NOT EXISTS email(rid INTEGER PRIMARY KEY, account TEXT NOT NULL, id TEXT NOT NULL,
            thread TEXT NOT NULL, received REAL NOT NULL, data BLOB NOT NULL, UNIQUE(account, id));
        CREATE INDEX IF NOT EXISTS email_thread ON email(account, thread);
        CREATE INDEX IF NOT EXISTS email_received ON email(account, received);
        CREATE TABLE IF NOT EXISTS email_box(box TEXT NOT NULL, rid INTEGER NOT NULL, PRIMARY KEY(box, rid)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS email_box_rid ON email_box(rid);
        CREATE TABLE IF NOT EXISTS body(rid INTEGER PRIMARY KEY, html TEXT NOT NULL, text TEXT NOT NULL,
            attachments BLOB, complete INTEGER NOT NULL DEFAULT 0);
        CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(subject, people, words, tokenize='unicode61 remove_diacritics 2');
        CREATE TABLE IF NOT EXISTS meta(account TEXT NOT NULL, key TEXT NOT NULL, value TEXT, PRIMARY KEY(account, key));
        CREATE TABLE IF NOT EXISTS pending(n INTEGER PRIMARY KEY, account TEXT NOT NULL, kind TEXT NOT NULL, data BLOB NOT NULL);
        """)
        return db
    }

    // MARK: Small SQLite helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if !ok, let err { NSLog("JCCACHE %@", String(cString: err)); sqlite3_free(err) }
        return ok
    }

    private enum Value {
        case text(String), real(Double), int(Int64), blob(Data), null
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Runs one statement, calling `row` for each result row.
    @discardableResult
    private func run(_ sql: String, _ args: [Value] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        guard let db = open() else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            NSLog("JCCACHE prepare failed: %@", String(cString: sqlite3_errmsg(db)))
            return false
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let n = Int32(i + 1)
            switch a {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(stmt, n, d)
            case .int(let v): sqlite3_bind_int64(stmt, n, v)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, n, $0.baseAddress, Int32(d.count), Self.transient) }
            case .null: sqlite3_bind_null(stmt, n)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row?(stmt); continue }
            if rc == SQLITE_DONE { return true }
            NSLog("JCCACHE step failed: %@", String(cString: sqlite3_errmsg(db)))
            return false
        }
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: p)
    }

    private static func blob(_ stmt: OpaquePointer, _ col: Int32) -> Data? {
        let n = Int(sqlite3_column_bytes(stmt, col))
        guard let p = sqlite3_column_blob(stmt, col), n > 0 else { return nil }
        return Data(bytes: p, count: n)
    }

    private func transaction(_ work: () -> Void) {
        _ = open()
        exec("BEGIN IMMEDIATE")
        work()
        exec("COMMIT")
    }

    private func emails(_ sql: String, _ args: [Value]) -> [Email] {
        var out: [Email] = []
        run(sql, args) { stmt in
            if let d = Self.blob(stmt, 0), let e = try? self.decoder.decode(Email.self, from: d) { out.append(e) }
        }
        return out
    }

    // MARK: Emails

    /// Saves emails as the lists show them (no bodies), replacing older copies.
    func save(_ list: [Email], account: String) {
        guard !list.isEmpty else { return }
        transaction {
            for e in list { put(e, account: account) }
        }
    }

    private func put(_ e: Email, account: String) {
        guard let data = try? encoder.encode(e) else { return }
        var rid: Int64 = 0
        run("""
            INSERT INTO email(account, id, thread, received, data) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(account, id) DO UPDATE SET thread = excluded.thread, received = excluded.received, data = excluded.data
            RETURNING rid
            """, [.text(account), .text(e.id), .text(e.threadId), .real(e.date.timeIntervalSince1970), .blob(data)]) { stmt in
            rid = sqlite3_column_int64(stmt, 0)
        }
        guard rid != 0 else { return }
        run("DELETE FROM email_box WHERE rid = ?", [.int(rid)])
        for (box, on) in e.mailboxIds where on {
            run("INSERT OR IGNORE INTO email_box(box, rid) VALUES(?, ?)", [.text(box), .int(rid)])
        }
        index(rid, e)
    }

    /// Keeps the search index in step: subject, the people on it, and the preview plus any saved text.
    private func index(_ rid: Int64, _ e: Email, body: String? = nil) {
        var text = body
        if text == nil {
            run("SELECT text FROM body WHERE rid = ?", [.int(rid)]) { stmt in text = Self.text(stmt, 0) }
        }
        let people = ((e.from ?? []) + (e.to ?? []) + (e.cc ?? []) + (e.bcc ?? []))
            .map { "\($0.name ?? "") \($0.email)" }.joined(separator: " ")
        run("DELETE FROM search WHERE rowid = ?", [.int(rid)])
        run("INSERT INTO search(rowid, subject, people, words) VALUES(?, ?, ?, ?)",
            [.int(rid), .text(e.subject ?? ""), .text(people), .text((e.preview ?? "") + "\n" + (text ?? ""))])
    }

    func remove(ids: [String], account: String) {
        guard !ids.isEmpty else { return }
        transaction {
            for id in ids {
                var rid: Int64 = 0
                run("SELECT rid FROM email WHERE account = ? AND id = ?", [.text(account), .text(id)]) { rid = sqlite3_column_int64($0, 0) }
                guard rid != 0 else { continue }
                run("DELETE FROM email_box WHERE rid = ?", [.int(rid)])
                run("DELETE FROM body WHERE rid = ?", [.int(rid)])
                run("DELETE FROM search WHERE rowid = ?", [.int(rid)])
                run("DELETE FROM email WHERE rid = ?", [.int(rid)])
            }
        }
    }

    func email(_ id: String, account: String) -> Email? {
        emails("SELECT data FROM email WHERE account = ? AND id = ?", [.text(account), .text(id)]).first
    }

    func emails(ids: [String], account: String) -> [Email] {
        ids.compactMap { email($0, account: account) }
    }

    /// The newest conversations in a folder, newest first: one row per conversation, like the server's lists.
    func list(box: String, account: String, limit: Int) -> [Email] {
        emails("""
            SELECT e.data, MAX(e.received) FROM email e JOIN email_box b ON b.rid = e.rid
            WHERE e.account = ? AND b.box = ?
            GROUP BY e.thread ORDER BY MAX(e.received) DESC LIMIT ?
            """, [.text(account), .text(box), .int(Int64(limit))])
    }

    /// Every email in a conversation, oldest first.
    func thread(_ thread: String, account: String) -> [Email] {
        emails("SELECT data FROM email WHERE account = ? AND thread = ? ORDER BY received", [.text(account), .text(thread)])
    }

    /// Searches saved mail. `box` narrows it to one folder; otherwise anything in a folder other than `skip`
    /// (Bin and Spam) counts, the same as the server's search.
    func search(_ words: String, account: String, box: String?, skip: [String], limit: Int) -> [Email] {
        guard let match = Self.match(words) else { return [] }
        var sql = """
            SELECT e.data, MAX(e.received) FROM search s JOIN email e ON e.rid = s.rowid
            WHERE search MATCH ? AND e.account = ?
            """
        var args: [Value] = [.text(match), .text(account)]
        if let box {
            sql += " AND EXISTS (SELECT 1 FROM email_box b WHERE b.rid = e.rid AND b.box = ?)"
            args.append(.text(box))
        } else if !skip.isEmpty {
            sql += " AND EXISTS (SELECT 1 FROM email_box b WHERE b.rid = e.rid AND b.box NOT IN (\(skip.map { _ in "?" }.joined(separator: ","))))"
            args += skip.map { .text($0) }
        }
        sql += " GROUP BY e.thread ORDER BY MAX(e.received) DESC LIMIT ?"
        args.append(.int(Int64(limit)))
        return emails(sql, args)
    }

    /// Turns what someone typed into an FTS5 query: every word must appear (matching the start of words), and
    /// from:, to: and subject: look only at the people or the subject.
    nonisolated static func match(_ typed: String) -> String? {
        var parts: [String] = []
        for raw in typed.split(whereSeparator: { $0.isWhitespace }) {
            var word = String(raw)
            var column = ""
            for (prefix, col) in [("from:", "people"), ("to:", "people"), ("cc:", "people"), ("subject:", "subject")]
                where word.lowercased().hasPrefix(prefix) {
                column = col + ":"
                word = String(word.dropFirst(prefix.count))
            }
            // Only letters and numbers reach FTS, so nothing typed can break the query.
            let pieces = word.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }.map { String(String.UnicodeScalarView($0)) }
            for p in pieces where !p.isEmpty { parts.append("\(column)\"\(p)\"*") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " AND ")
    }

    // MARK: Bodies

    func page(_ id: String, account: String) -> SavedPage? {
        var out: SavedPage?
        run("""
            SELECT b.html, b.text, b.attachments, b.complete FROM body b JOIN email e ON e.rid = b.rid
            WHERE e.account = ? AND e.id = ?
            """, [.text(account), .text(id)]) { stmt in
            let files = Self.blob(stmt, 2).flatMap { try? self.decoder.decode([Attachment].self, from: $0) } ?? []
            out = SavedPage(html: Self.text(stmt, 0) ?? "", text: Self.text(stmt, 1) ?? "", attachments: files,
                            complete: sqlite3_column_int(stmt, 3) != 0)
        }
        return out
    }

    func savePage(_ page: SavedPage, id: String, account: String) {
        transaction {
            var rid: Int64 = 0
            var data: Data?
            run("SELECT rid, data FROM email WHERE account = ? AND id = ?", [.text(account), .text(id)]) { stmt in
                rid = sqlite3_column_int64(stmt, 0)
                data = Self.blob(stmt, 1)
            }
            guard rid != 0 else { return }
            let files = (try? encoder.encode(page.attachments)) ?? Data()
            run("INSERT OR REPLACE INTO body(rid, html, text, attachments, complete) VALUES(?, ?, ?, ?, ?)",
                [.int(rid), .text(page.html), .text(page.text), .blob(files), .int(page.complete ? 1 : 0)])
            if let data, let e = try? decoder.decode(Email.self, from: data) { index(rid, e, body: page.text) }
        }
    }

    /// Emails received since `since` whose text isn't saved yet, newest first.
    func missingBodies(account: String, since: Date, limit: Int) -> [String] {
        var ids: [String] = []
        run("""
            SELECT e.id FROM email e LEFT JOIN body b ON b.rid = e.rid
            WHERE e.account = ? AND e.received >= ? AND b.rid IS NULL
            ORDER BY e.received DESC LIMIT ?
            """, [.text(account), .real(since.timeIntervalSince1970), .int(Int64(limit))]) { stmt in
            if let id = Self.text(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    /// Drops saved text older than the window chosen in Settings. The emails stay in lists and search.
    func trimBodies(before: Date) {
        run("DELETE FROM body WHERE rid IN (SELECT rid FROM email WHERE received < ?)", [.real(before.timeIntervalSince1970)])
    }

    // MARK: Account details

    func meta(_ key: String, account: String) -> String? {
        var out: String?
        run("SELECT value FROM meta WHERE account = ? AND key = ?", [.text(account), .text(key)]) { out = Self.text($0, 0) }
        return out
    }

    func setMeta(_ key: String, _ value: String?, account: String) {
        if let value {
            run("INSERT OR REPLACE INTO meta(account, key, value) VALUES(?, ?, ?)", [.text(account), .text(key), .text(value)])
        } else {
            run("DELETE FROM meta WHERE account = ? AND key = ?", [.text(account), .text(key)])
        }
    }

    func saveValue<T: Encodable>(_ value: T, as key: String, account: String) {
        guard let d = try? encoder.encode(value) else { return }
        setMeta(key, String(decoding: d, as: UTF8.self), account: account)
    }

    func value<T: Decodable>(_ type: T.Type, _ key: String, account: String) -> T? {
        guard let s = meta(key, account: account) else { return nil }
        return try? decoder.decode(T.self, from: Data(s.utf8))
    }

    // MARK: Waiting to go to the server

    func queue(_ p: Pending) {
        run("INSERT INTO pending(account, kind, data) VALUES(?, ?, ?)", [.text(p.account), .text(p.kind), .blob(p.data)])
    }

    func pending(account: String? = nil) -> [Pending] {
        var out: [Pending] = []
        let sql = "SELECT n, account, kind, data FROM pending" + (account == nil ? "" : " WHERE account = ?") + " ORDER BY n"
        run(sql, account.map { [.text($0)] } ?? []) { stmt in
            out.append(Pending(n: sqlite3_column_int64(stmt, 0), account: Self.text(stmt, 1) ?? "",
                               kind: Self.text(stmt, 2) ?? "", data: Self.blob(stmt, 3) ?? Data()))
        }
        return out
    }

    func done(_ p: Pending) { run("DELETE FROM pending WHERE n = ?", [.int(p.n)]) }

    // MARK: Space and clearing

    /// Space the saved mail takes, in bytes, attachments included.
    func size() -> Int64 {
        var pages: Int64 = 0, pageSize: Int64 = 0
        run("PRAGMA page_count") { pages = sqlite3_column_int64($0, 0) }
        run("PRAGMA page_size") { pageSize = sqlite3_column_int64($0, 0) }
        var files: Int64 = 0
        if let walk = FileManager.default.enumerator(at: Self.files, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in walk { files += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return pages * pageSize + files
    }

    /// Forgets one account's saved mail, or everyone's. Things waiting to go to the server are kept unless the
    /// account itself is going.
    func clear(account: String? = nil, keepPending: Bool = true) {
        transaction {
            if let account {
                run("DELETE FROM email_box WHERE rid IN (SELECT rid FROM email WHERE account = ?)", [.text(account)])
                run("DELETE FROM body WHERE rid IN (SELECT rid FROM email WHERE account = ?)", [.text(account)])
                run("DELETE FROM search WHERE rowid IN (SELECT rid FROM email WHERE account = ?)", [.text(account)])
                run("DELETE FROM email WHERE account = ?", [.text(account)])
                run("DELETE FROM meta WHERE account = ?", [.text(account)])
                if !keepPending { run("DELETE FROM pending WHERE account = ?", [.text(account)]) }
            } else {
                run("DELETE FROM email_box"); run("DELETE FROM body"); run("DELETE FROM search")
                run("DELETE FROM email"); run("DELETE FROM meta")
                if !keepPending { run("DELETE FROM pending") }
            }
        }
        if account == nil { try? FileManager.default.removeItem(at: Self.files) }
        exec("PRAGMA wal_checkpoint(TRUNCATE)")
        exec("VACUUM")
    }
}
