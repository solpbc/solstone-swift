// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SQLite3
import CryptoKit

nonisolated enum SafariBrowserError: Error { case storage, malformed, full }

nonisolated struct SafariBrowserPeriod: Sendable {
    let id: String
    let started: Double
    let ended: Double
    let zone: String
    let payload: Data
}

/// What the app shows for the Safari source, read from the shared store.
nonisolated struct SafariBrowserSnapshot: Sendable, Equatable {
    var confirmed: Bool
    var paused: Bool
    /// Pages the extension handed over that the app has not yet taken into its send queue.
    var heldBytes: Int
    /// Browser pages the app's send queue still holds, as last published by the app.
    var queuedBytes: Int
    /// When the extension last handed a page over, if ever.
    var lastAccepted: Date?
    /// When Safari's extension last said hello, if ever: the only sign the app has
    /// that the owner turned it on.
    var lastContact: Date?
    var full: Bool
}

/// Durable custody for Safari pages on the phone. The extension's native handler
/// writes; the app reads, seals and adopts. Each instance owns one SQLite
/// connection. BEGIN IMMEDIATE serializes the app and the handler; synchronous
/// FULL commits precede every receipt the extension sees.
///
/// Capture authority is the app's pairing confirmation plus the owner's pause,
/// both held here and checked inside the same transaction as intake. Held pages
/// carry no journal binding: they wait while unpaired and go to whichever
/// journal the app is confirmed with when it next runs.
nonisolated final class SafariBrowserStore {
    let root: URL
    private var db: OpaquePointer?

    /// Bytes held on the phone before the app has taken them, whatever the reason.
    static let defaultQuota = 64 * 1024 * 1024
    let quota: Int
    /// Hard cap on dedup identities, independent of the retention window.
    static let tombstoneCap = 100_000
    /// A period is sealed into its own segment at this age or size.
    static let periodSeconds: Double = 300
    static let periodBytes = 8 * 1024 * 1024
    static let freshnessMs = 5000

    convenience init() throws {
        try self.init(root: AppGroupContainer.rootURL().appendingPathComponent("SafariBrowser", isDirectory: true))
    }

    init(root: URL, quota: Int = SafariBrowserStore.defaultQuota) throws {
        self.root = root
        self.quota = quota
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedRoot = root
        try protectedRoot.setResourceValues(values)
        guard sqlite3_open_v2(root.appendingPathComponent("inbox.sqlite").path, &self.db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(self.db); self.db = nil; throw SafariBrowserError.storage
        }
        sqlite3_busy_timeout(self.db, 3000)
        do {
            try self.sql("PRAGMA journal_mode=WAL")
            try self.sql("PRAGMA synchronous=FULL")
            try self.sql("PRAGMA fullfsync=ON")
            try self.sql("PRAGMA checkpoint_fullfsync=ON")
            try self.sql("CREATE TABLE IF NOT EXISTS control (id INTEGER PRIMARY KEY CHECK(id=1), confirmed INTEGER NOT NULL, paused INTEGER NOT NULL, generation TEXT NOT NULL, queued INTEGER NOT NULL DEFAULT 0, full INTEGER NOT NULL DEFAULT 0, contact REAL, lastaccepted REAL)")
            try self.sql("INSERT OR IGNORE INTO control(id,confirmed,paused,generation) VALUES(1,0,0,?)", [.text(UUID().uuidString)])
            try self.sql("CREATE TABLE IF NOT EXISTS periods (id TEXT PRIMARY KEY, started REAL NOT NULL, last REAL, ended REAL, zone TEXT NOT NULL, payload BLOB NOT NULL, handoff INTEGER NOT NULL DEFAULT 0, adopted INTEGER NOT NULL DEFAULT 0)")
            try self.sql("CREATE TABLE IF NOT EXISTS batches (inst TEXT NOT NULL, batch TEXT NOT NULL, digest TEXT NOT NULL, period TEXT NOT NULL, accepted REAL NOT NULL, PRIMARY KEY(inst,batch))")
            try self.sql("CREATE INDEX IF NOT EXISTS batches_accepted ON batches(accepted)")
            try self.sql("CREATE TABLE IF NOT EXISTS contexts (inst TEXT NOT NULL, ctx TEXT NOT NULL, period TEXT NOT NULL, PRIMARY KEY(inst,ctx))")
            try self.sql("CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, inst TEXT NOT NULL, seen REAL NOT NULL)")
        } catch { sqlite3_close(self.db); self.db = nil; throw error }
    }

    deinit { sqlite3_close(self.db) }

    nonisolated enum Value { case text(String), number(Double), data(Data), null }
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    @discardableResult
    private func query(_ sql: String, _ args: [Value] = []) throws -> [[String: Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { throw SafariBrowserError.storage }
        defer { sqlite3_finalize(stmt) }
        for (index, arg) in args.enumerated() {
            let pos = Int32(index + 1)
            let code: Int32
            switch arg {
            case .text(let value): code = sqlite3_bind_text(stmt, pos, value, -1, Self.transient)
            case .number(let value): code = sqlite3_bind_double(stmt, pos, value)
            case .data(let value):
                code = value.withUnsafeBytes { sqlite3_bind_blob(stmt, pos, $0.baseAddress, Int32(value.count), Self.transient) }
            case .null: code = sqlite3_bind_null(stmt, pos)
            }
            guard code == SQLITE_OK else { throw SafariBrowserError.storage }
        }
        var rows: [[String: Value]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return rows }
            // A full disk is the one write failure the owner can act on.
            if code == SQLITE_FULL { throw SafariBrowserError.full }
            guard code == SQLITE_ROW else { throw SafariBrowserError.storage }
            var row: [String: Value] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let key = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_TEXT: row[key] = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_INTEGER, SQLITE_FLOAT: row[key] = .number(sqlite3_column_double(stmt, i))
                case SQLITE_BLOB:
                    let size = Int(sqlite3_column_bytes(stmt, i))
                    row[key] = .data(size == 0 ? Data() : Data(bytes: sqlite3_column_blob(stmt, i)!, count: size))
                default: row[key] = .null
                }
            }
            rows.append(row)
        }
    }

    private func sql(_ statement: String, _ args: [Value] = []) throws { _ = try self.query(statement, args) }

    private func number(_ statement: String, _ args: [Value] = []) throws -> Double {
        try self.query(statement, args).first?.values.first?.number ?? 0
    }

    private func transaction<T>(_ action: () throws -> T) throws -> T {
        try self.sql("BEGIN IMMEDIATE")
        do {
            let result = try action()
            try self.sql("COMMIT")
            return result
        } catch {
            _ = try? self.query("ROLLBACK")
            throw error
        }
    }

    // MARK: authority, written by the app

    /// The app's pairing confirmation. Any change mints a new generation, so a
    /// batch stamped under the old one is refused.
    func setConfirmed(_ confirmed: Bool) throws {
        try self.transaction {
            let row = try self.control()
            guard row.confirmed != confirmed else { return }
            try self.sql("UPDATE control SET confirmed=?,generation=? WHERE id=1",
                [.number(confirmed ? 1 : 0), .text(UUID().uuidString)])
        }
    }

    /// The owner's pause for the Safari source.
    func setPaused(_ paused: Bool) throws {
        try self.transaction {
            guard try self.control().paused != paused else { return }
            try self.sql("UPDATE control SET paused=?,generation=? WHERE id=1",
                [.number(paused ? 1 : 0), .text(UUID().uuidString)])
        }
    }

    /// What the app's send queue still holds for this source. Status only:
    /// nothing here retires or releases custody.
    func setQueuedBytes(_ bytes: Int) throws {
        try self.sql("UPDATE control SET queued=? WHERE id=1", [.number(Double(max(0, bytes)))])
    }

    private func control() throws -> (confirmed: Bool, paused: Bool, generation: String, queued: Int, full: Bool) {
        guard let row = try self.query("SELECT * FROM control WHERE id=1").first,
            case .number(let confirmed) = row["confirmed"], case .number(let paused) = row["paused"],
            case .text(let generation) = row["generation"], case .number(let queued) = row["queued"],
            case .number(let full) = row["full"] else { throw SafariBrowserError.storage }
        return (confirmed == 1, paused == 1, generation, Int(queued), full == 1)
    }

    // MARK: periods

    private func heldBytes() throws -> Double {
        try self.number("SELECT COALESCE(SUM(length(payload)),0) FROM periods WHERE adopted=0")
    }

    /// Seals an open period that has reached its age or size, so no segment
    /// grows without bound while the app stays closed.
    private func rotate(now: Double) throws {
        try self.sql("UPDATE periods SET ended=COALESCE(last,started),handoff=1 WHERE ended IS NULL AND length(payload)>0 AND (? - started >= ? OR length(payload) >= ?)",
            [.number(now), .number(Self.periodSeconds), .number(Double(Self.periodBytes))])
    }

    private func openPeriod(now: Double) throws -> String {
        if let id = try self.query("SELECT id FROM periods WHERE ended IS NULL LIMIT 1").first?["id"]?.text { return id }
        let id = UUID().uuidString
        try self.sql("INSERT INTO periods(id,started,zone,payload) VALUES(?,?,?,X'')",
            [.text(id), .number(now), .text(TimeZone.current.identifier)])
        try self.sql("DELETE FROM contexts WHERE period NOT IN (SELECT id FROM periods WHERE ended IS NULL)")
        return id
    }

    // MARK: the extension's exchange

    func exchange(connection: String, frame: String?, projection: BrowserContractProjection,
                  now: Double = Date().timeIntervalSince1970,
                  beforeCustodyCommit: (() throws -> Void)? = nil) throws -> [String] {
        guard connection.utf8.count <= 128, !connection.isEmpty else { throw SafariBrowserError.malformed }
        return try self.transaction {
            try self.sql("DELETE FROM sessions WHERE seen < ?", [.number(now - 60)])
            // The contract's dedup window: a lost reply is retried well inside it.
            try self.sql("DELETE FROM batches WHERE accepted < ?",
                [.number(now - Double(projection.policy.acceptedRetentionMs) / 1000)])
            let control = try self.control()
            try self.rotate(now: now)
            let period = try self.openPeriod(now: now)
            var full = control.full
            var replies: [[String: Any]] = []
            var hello = false
            var acceptedNewBatch = false
            if let frame {
                guard let data = frame.data(using: .utf8) else { throw SafariBrowserError.malformed }
                switch BrowserPayloadDecoder.decode(bytes: data, direction: "extension_to_host", projection: projection) {
                case .accept(.hello(let request)):
                    guard request.brand == "safari", request.protocolVersion == projection.wireProtocol else {
                        return ["{\"type\":\"unsupported\",\"protocol\":1,\"behind\":\"app\"}"]
                    }
                    try self.sql("INSERT OR REPLACE INTO sessions VALUES(?,?,?)", [.text(connection), .text(request.inst), .number(now)])
                    try self.sql("UPDATE control SET contact=? WHERE id=1", [.number(now)])
                    hello = true
                case .accept(.batch(let batch)):
                    guard let inst = try self.query("SELECT inst FROM sessions WHERE id=?", [.text(connection)]).first?["inst"]?.text,
                        inst == batch.inst else { throw SafariBrowserError.malformed }
                    let digest = SHA256.hash(data: Data(batch.records.flatMap { Array($0.rawSlice) })).map { String(format: "%02x", $0) }.joined()
                    let prior = try self.query("SELECT digest,period FROM batches WHERE inst=? AND batch=?", [.text(inst), .text(batch.batchId)]).first
                    var receipt: [String: Any] = ["type": "accepted", "destination_generation": batch.destinationGeneration,
                        "inst": inst, "batch_id": batch.batchId]
                    func reject(_ reason: String) { receipt["result"] = "rejected"; receipt["reason"] = reason; receipt["class"] = "retryable" }
                    if let prior {
                        guard prior["digest"]?.text == digest, let savedPeriod = prior["period"]?.text else { throw SafariBrowserError.malformed }
                        receipt["result"] = "duplicate"; receipt["period_id"] = savedPeriod
                    } else if !control.confirmed || control.paused || batch.destinationGeneration != control.generation {
                        // Stale or withdrawn authority: nothing new is taken in.
                        reject("resource_exhausted")
                    } else if batch.records[0].t == "delta",
                              try self.query("SELECT 1 FROM contexts WHERE inst=? AND ctx=? AND period=?",
                                  [.text(inst), .text(batch.records[0].ctx), .text(period)]).isEmpty {
                        reject("snapshot_required")
                    } else {
                        var jsonl = Data()
                        for record in batch.records { jsonl.append(record.rawSlice); jsonl.append(10) }
                        let held = try self.heldBytes()
                        let identities = try self.number("SELECT count(*) FROM batches")
                        if held + Double(jsonl.count) > Double(self.quota) || identities >= Double(Self.tombstoneCap) {
                            full = true
                            reject("resource_exhausted")
                        } else {
                            try self.sql("SAVEPOINT intake")
                            do {
                                // The payload and its dedup identity commit together.
                                try self.sql("UPDATE periods SET started=CASE WHEN length(payload)=0 THEN ? ELSE started END, last=?, payload=CAST(payload || ? AS BLOB) WHERE id=? AND ended IS NULL",
                                    [.number(now), .number(now), .data(jsonl), .text(period)])
                                try self.sql("INSERT INTO batches VALUES(?,?,?,?,?)", [.text(inst), .text(batch.batchId), .text(digest), .text(period), .number(now)])
                                for record in batch.records where record.t != "delta" {
                                    try self.sql("INSERT OR REPLACE INTO contexts VALUES(?,?,?)", [.text(inst), .text(record.ctx), .text(period)])
                                }
                                try self.sql("UPDATE control SET lastaccepted=? WHERE id=1", [.number(now)])
                                try self.sql("RELEASE intake")
                                receipt["result"] = "accepted"; receipt["period_id"] = period
                                acceptedNewBatch = true
                                full = false
                            } catch SafariBrowserError.full {
                                try self.sql("ROLLBACK TO intake")
                                try self.sql("RELEASE intake")
                                full = true
                                reject("resource_exhausted")
                            }
                        }
                    }
                    replies.append(receipt)
                default: throw SafariBrowserError.malformed
                }
            }
            if full != control.full { try? self.sql("UPDATE control SET full=? WHERE id=1", [.number(full ? 1 : 0)]) }
            try? self.sql("UPDATE sessions SET seen=? WHERE id=?", [.number(now), .text(connection)])
            let held = try self.heldBytes()
            let oldest = try self.query("SELECT MIN(started) AS s FROM periods WHERE adopted=0 AND length(payload)>0").first?["s"]?.number
            let stale = oldest.map { now - $0 > Double(projection.policy.spoolAgeMs) / 1000 } ?? false
            let capture = !control.confirmed ? "not_paired" : control.paused ? "paused" : full ? "intake_off" : "permitted"
            var state: [String: Any] = ["type": hello ? "hello_ack" : "state", "capture": capture,
                "delivery": held > 0 || control.queued > 0 ? "kept_locally" : "idle",
                "freshness_ms": control.confirmed ? Self.freshnessMs : 0,
                "destination_generation": control.confirmed ? control.generation as Any : NSNull(),
                "period_id": control.confirmed ? period as Any : NSNull(),
                "custody": ["full": full, "stale": stale]]
            if full { state["failure"] = "resource_exhausted" }
            replies.append(state)
            let frames = try replies.map { value in
                let validated = try BrowserPayloadDecoder.validatedHostMessage(value, projection: projection)
                return String(decoding: BrowserPayloadDecoder.encodeHostToExtension(validated), as: UTF8.self)
            }
            if acceptedNewBatch { try beforeCustodyCommit?() }
            return frames
        }
    }

    // MARK: the app's adoption

    /// Seal before async handoff. No later handler transaction can append to
    /// these bytes; the next batch opens a new period and snapshot boundary.
    func prepareHandoffs(now: Double = Date().timeIntervalSince1970) throws -> [SafariBrowserPeriod] {
        try self.transaction {
            try self.sql("UPDATE periods SET ended=COALESCE(last,?),handoff=1 WHERE ended IS NULL AND length(payload)>0", [.number(now)])
            return try self.query("SELECT * FROM periods WHERE adopted=0 AND handoff=1 ORDER BY started").map { row in
                guard let id = row["id"]?.text, let start = row["started"]?.number,
                    let end = row["ended"]?.number, let zone = row["zone"]?.text,
                    case .data(let payload) = row["payload"] else { throw SafariBrowserError.storage }
                return SafariBrowserPeriod(id: id, started: start, ended: end, zone: zone, payload: payload)
            }
        }
    }

    /// Retires a sealed period's bytes once the send queue durably owns them.
    /// Only that durable ownership is retirement authority. Dedup identities
    /// stay for their retention window.
    func adopt(id: String) throws {
        try self.transaction {
            try self.sql("UPDATE periods SET adopted=1,handoff=0,payload=X'' WHERE id=? AND ended IS NOT NULL AND handoff=1", [.text(id)])
            guard sqlite3_changes(self.db) == 1 else { throw SafariBrowserError.storage }
            try self.sql("DELETE FROM periods WHERE adopted=1 AND id NOT IN (SELECT period FROM batches)")
            try self.sql("UPDATE control SET full=0 WHERE id=1")
        }
    }

    func admitsDispatch() throws -> Bool {
        try self.number("SELECT count(*) FROM periods WHERE handoff=1 AND adopted=0") == 0
    }

    func snapshot() throws -> SafariBrowserSnapshot {
        let c = try self.control()
        // Kept on the control row: dedup identities and adopted periods are pruned.
        let row = try self.query("SELECT contact, lastaccepted FROM control WHERE id=1").first
        let last = row?["lastaccepted"]?.number
        let contact = row?["contact"]?.number
        return SafariBrowserSnapshot(confirmed: c.confirmed, paused: c.paused, heldBytes: Int(try self.heldBytes()),
            queuedBytes: c.queued, lastAccepted: last.map { Date(timeIntervalSince1970: $0) },
            lastContact: contact.map { Date(timeIntervalSince1970: $0) }, full: c.full)
    }

    func inventory() throws -> [String: Any] {
        let c = try self.control()
        return ["confirmed": c.confirmed, "paused": c.paused, "heldBytes": try self.heldBytes(), "queuedBytes": c.queued,
            "acceptedBatches": try self.number("SELECT count(*) FROM batches"),
            "periods": try self.number("SELECT count(*) FROM periods"),
            "pendingPeriods": try self.number("SELECT count(*) FROM periods WHERE adopted=0 AND length(payload)>0")]
    }
}

private extension SafariBrowserStore.Value {
    nonisolated var text: String? { if case .text(let value) = self { value } else { nil } }
    nonisolated var number: Double? { if case .number(let value) = self { value } else { nil } }
}
