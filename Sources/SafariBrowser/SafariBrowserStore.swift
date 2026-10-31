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

/// A request owns one SQLite connection. BEGIN IMMEDIATE serializes app and
/// extension writers; FULL synchronous commits precede every custody receipt.
nonisolated final class SafariBrowserStore {
    let root: URL
    private var db: OpaquePointer?
    static let quota = 64 * 1024 * 1024

    convenience init() throws {
        try self.init(root: AppGroupContainer.rootURL().appendingPathComponent("SafariBrowser", isDirectory: true))
    }

    init(root: URL) throws {
        self.root = root
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
            try self.sql("CREATE TABLE IF NOT EXISTS control (id INTEGER PRIMARY KEY CHECK(id=1), confirmed INTEGER NOT NULL, paused INTEGER NOT NULL, generation TEXT NOT NULL)")
            try self.sql("INSERT OR IGNORE INTO control VALUES(1,0,0,?)", [.text(UUID().uuidString)])
            try self.sql("CREATE TABLE IF NOT EXISTS periods (id TEXT PRIMARY KEY, started REAL NOT NULL, ended REAL, zone TEXT NOT NULL, payload BLOB NOT NULL, handoff INTEGER NOT NULL DEFAULT 0, adopted INTEGER NOT NULL DEFAULT 0)")
            try self.sql("CREATE TABLE IF NOT EXISTS batches (inst TEXT NOT NULL, batch TEXT NOT NULL, digest TEXT NOT NULL, period TEXT NOT NULL, PRIMARY KEY(inst,batch))")
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

    func setConfirmed(_ confirmed: Bool) throws {
        try self.transaction {
            let row = try self.control()
            guard row.confirmed != confirmed else { return }
            try self.sql("UPDATE control SET confirmed=?,generation=? WHERE id=1",
                [.number(confirmed ? 1 : 0), .text(UUID().uuidString)])
        }
    }

    func setPaused(_ paused: Bool) throws {
        try self.transaction {
            try self.sql("UPDATE control SET paused=?,generation=? WHERE id=1",
                [.number(paused ? 1 : 0), .text(UUID().uuidString)])
        }
    }

    private func control() throws -> (confirmed: Bool, paused: Bool, generation: String) {
        guard let row = try self.query("SELECT * FROM control WHERE id=1").first,
            case .number(let confirmed) = row["confirmed"], case .number(let paused) = row["paused"],
            case .text(let generation) = row["generation"] else { throw SafariBrowserError.storage }
        return (confirmed == 1, paused == 1, generation)
    }

    private func openPeriod(now: Double) throws -> String {
        if let row = try self.query("SELECT id FROM periods WHERE ended IS NULL LIMIT 1").first,
           case .text(let id) = row["id"] { return id }
        let id = UUID().uuidString
        try self.sql("INSERT INTO periods(id,started,zone,payload) VALUES(?,?,?,X'')",
            [.text(id), .number(now), .text(TimeZone.current.identifier)])
        return id
    }

    func exchange(connection: String, frame: String?, projection: BrowserContractProjection,
                  now: Double = Date().timeIntervalSince1970,
                  beforeCustodyCommit: (() throws -> Void)? = nil) throws -> [String] {
        guard connection.utf8.count <= 128, !connection.isEmpty else { throw SafariBrowserError.malformed }
        return try self.transaction {
            try self.sql("DELETE FROM sessions WHERE seen < ?", [.number(now - 60)])
            let control = try self.control()
            let period = try self.openPeriod(now: now)
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
                    hello = true
                case .accept(.batch(let batch)):
                    guard let session = try self.query("SELECT inst FROM sessions WHERE id=?", [.text(connection)]).first,
                        case .text(let inst) = session["inst"], inst == batch.inst else { throw SafariBrowserError.malformed }
                    let digest = SHA256.hash(data: Data(batch.records.flatMap { Array($0.rawSlice) })).map { String(format: "%02x", $0) }.joined()
                    let prior = try self.query("SELECT digest,period FROM batches WHERE inst=? AND batch=?", [.text(inst), .text(batch.batchId)]).first
                    var receipt: [String: Any] = ["type": "accepted", "destination_generation": control.generation,
                        "inst": inst, "batch_id": batch.batchId]
                    if let prior {
                        guard case .text(let savedHash) = prior["digest"], savedHash == digest,
                            case .text(let savedPeriod) = prior["period"] else { throw SafariBrowserError.malformed }
                        receipt["result"] = "duplicate"; receipt["period_id"] = savedPeriod
                    } else if !control.confirmed || control.paused || batch.destinationGeneration != control.generation {
                        receipt["result"] = "rejected"; receipt["reason"] = "resource_exhausted"; receipt["class"] = "retryable"
                    } else {
                        let context = batch.records[0].ctx
                        let hasSnapshot = batch.records.contains { $0.t == "segment_start" }
                        let currentContext = try self.query("SELECT period FROM contexts WHERE inst=? AND ctx=?", [.text(inst), .text(context)]).first
                        let known = currentContext?["period"]?.text == period
                        if !hasSnapshot && !known {
                            receipt["result"] = "rejected"; receipt["reason"] = "snapshot_required"; receipt["class"] = "retryable"
                        } else {
                            let used = try self.query("SELECT COALESCE(SUM(length(payload)),0) AS bytes FROM periods").first?["bytes"]?.number ?? Double(Self.quota)
                            var jsonl = Data()
                            for record in batch.records { jsonl.append(record.rawSlice); jsonl.append(10) }
                            guard used + Double(jsonl.count) <= Double(Self.quota),
                                (try self.query("SELECT count(*) AS n FROM batches").first?["n"]?.number ?? 100000) < 100000 else {
                                throw SafariBrowserError.full
                            }
                            // The payload and its dedup identity commit together.
                            try self.sql("UPDATE periods SET payload=CAST(payload || ? AS BLOB) WHERE id=? AND ended IS NULL", [.data(jsonl), .text(period)])
                            try self.sql("INSERT INTO batches VALUES(?,?,?,?)", [.text(inst), .text(batch.batchId), .text(digest), .text(period)])
                            try self.sql("INSERT OR REPLACE INTO contexts VALUES(?,?,?)", [.text(inst), .text(context), .text(period)])
                            receipt["result"] = "accepted"; receipt["period_id"] = period
                            acceptedNewBatch = true
                        }
                    }
                    replies.append(receipt)
                default: throw SafariBrowserError.malformed
                }
            }
            try self.sql("UPDATE sessions SET seen=? WHERE id=?", [.number(now), .text(connection)])
            let capture = !control.confirmed ? "not_paired" : control.paused ? "paused" : "permitted"
            replies.append(["type": hello ? "hello_ack" : "state", "capture": capture,
                "delivery": "kept_locally", "freshness_ms": control.confirmed ? 5000 : 0,
                "destination_generation": control.confirmed ? control.generation as Any : NSNull(),
                "period_id": control.confirmed ? period as Any : NSNull(), "custody": ["full": false, "stale": false]])
            let frames = try replies.map { value in
                let validated = try BrowserPayloadDecoder.validatedHostMessage(value, projection: projection)
                return String(decoding: BrowserPayloadDecoder.encodeHostToExtension(validated), as: UTF8.self)
            }
            if acceptedNewBatch { try beforeCustodyCommit?() }
            return frames
        }
    }

    /// Seal before async handoff. No subsequent handler transaction can append
    /// to these bytes; a new request gets a new period and snapshot boundary.
    func prepareHandoffs(now: Double = Date().timeIntervalSince1970) throws -> [SafariBrowserPeriod] {
        try self.transaction {
            try self.sql("UPDATE periods SET ended=?,handoff=1 WHERE ended IS NULL AND length(payload)>0", [.number(now)])
            return try self.query("SELECT * FROM periods WHERE adopted=0 AND handoff=1 ORDER BY started").map { row in
                guard let id = row["id"]?.text, let start = row["started"]?.number,
                    let end = row["ended"]?.number, let zone = row["zone"]?.text,
                    case .data(let payload) = row["payload"] else { throw SafariBrowserError.storage }
                return SafariBrowserPeriod(id: id, started: start, ended: end, zone: zone, payload: payload)
            }
        }
    }

    func adopt(id: String) throws {
        try self.transaction {
            try self.sql("UPDATE periods SET adopted=1,handoff=0,payload=X'' WHERE id=? AND ended IS NOT NULL AND handoff=1", [.text(id)])
            guard sqlite3_changes(self.db) == 1 else { throw SafariBrowserError.storage }
        }
    }

    func admitsDispatch() throws -> Bool {
        try self.query("SELECT count(*) AS n FROM periods WHERE handoff=1 AND adopted=0").first?["n"]?.number == 0
    }

    func inventory() throws -> [String: Any] {
        let c = try self.control()
        return ["confirmed": c.confirmed, "paused": c.paused,
            "heldBytes": try self.query("SELECT COALESCE(SUM(length(payload)),0) AS n FROM periods").first?["n"]?.number ?? 0,
            "acceptedBatches": try self.query("SELECT count(*) AS n FROM batches").first?["n"]?.number ?? 0,
            "adoptedPeriods": try self.query("SELECT count(*) AS n FROM periods WHERE adopted=1").first?["n"]?.number ?? 0]
    }
}

private extension SafariBrowserStore.Value {
    nonisolated var text: String? { if case .text(let value) = self { value } else { nil } }
    nonisolated var number: Double? { if case .number(let value) = self { value } else { nil } }
}
