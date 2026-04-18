const std = @import("std");
const models = @import("models.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Db = struct {
    allocator: std.mem.Allocator,
    handle: *c.sqlite3,

    pub fn open(allocator: std.mem.Allocator, path: []const u8, readonly: bool) !Db {
        const c_path = try allocator.dupeZ(u8, path);
        defer allocator.free(c_path);

        var db_handle: ?*c.sqlite3 = null;
        const flags: c_int = if (readonly)
            c.SQLITE_OPEN_READONLY
        else
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;

        if (c.sqlite3_open_v2(c_path.ptr, &db_handle, flags, null) != c.SQLITE_OK) {
            if (db_handle) |handle| _ = c.sqlite3_close(handle);
            return error.SqliteOpenFailed;
        }

        var db = Db{
            .allocator = allocator,
            .handle = db_handle.?,
        };
        if (!readonly) try db.initSchema();
        return db;
    }

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn initSchema(self: *Db) !void {
        try self.exec(
            \\PRAGMA journal_mode=WAL;
            \\PRAGMA synchronous=NORMAL;
            \\CREATE TABLE IF NOT EXISTS battery_samples (
            \\  ts_wall INTEGER NOT NULL,
            \\  ts_mono_ns INTEGER NOT NULL,
            \\  percent REAL NOT NULL,
            \\  ac_online INTEGER NOT NULL,
            \\  status TEXT NOT NULL,
            \\  power_w REAL,
            \\  energy_now_wh REAL,
            \\  energy_full_wh REAL,
            \\  source TEXT NOT NULL,
            \\  confidence TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_battery_samples_ts ON battery_samples(ts_wall);
            \\CREATE TABLE IF NOT EXISTS events (
            \\  ts_start INTEGER NOT NULL,
            \\  ts_end INTEGER NOT NULL,
            \\  kind TEXT NOT NULL,
            \\  value TEXT NOT NULL,
            \\  details TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_events_start ON events(ts_start);
            \\CREATE TABLE IF NOT EXISTS bucket_live_samples (
            \\  ts_wall INTEGER NOT NULL,
            \\  bucket_key TEXT NOT NULL,
            \\  bucket_label TEXT NOT NULL,
            \\  estimated_w REAL NOT NULL,
            \\  score REAL NOT NULL,
            \\  confidence TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_bucket_live_samples_ts ON bucket_live_samples(ts_wall);
            \\CREATE TABLE IF NOT EXISTS process_live_samples (
            \\  ts_wall INTEGER NOT NULL,
            \\  pid INTEGER NOT NULL,
            \\  process_label TEXT NOT NULL,
            \\  bucket_label TEXT NOT NULL,
            \\  estimated_w REAL NOT NULL,
            \\  score REAL NOT NULL,
            \\  confidence TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_process_live_samples_ts ON process_live_samples(ts_wall);
            \\CREATE TABLE IF NOT EXISTS bucket_impact_samples (
            \\  ts_wall INTEGER NOT NULL,
            \\  bucket_key TEXT NOT NULL,
            \\  bucket_label TEXT NOT NULL,
            \\  estimated_energy_wh REAL NOT NULL,
            \\  estimated_battery_pct REAL NOT NULL,
            \\  estimated_avg_w REAL NOT NULL,
            \\  confidence TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_bucket_impact_samples_ts ON bucket_impact_samples(ts_wall);
            \\CREATE TABLE IF NOT EXISTS process_impact_samples (
            \\  ts_wall INTEGER NOT NULL,
            \\  pid INTEGER NOT NULL,
            \\  process_label TEXT NOT NULL,
            \\  bucket_label TEXT NOT NULL,
            \\  estimated_energy_wh REAL NOT NULL,
            \\  estimated_battery_pct REAL NOT NULL,
            \\  estimated_avg_w REAL NOT NULL,
            \\  confidence TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_process_impact_samples_ts ON process_impact_samples(ts_wall);
            \\CREATE TABLE IF NOT EXISTS state_latest (
            \\  key TEXT PRIMARY KEY,
            \\  section TEXT NOT NULL,
            \\  value TEXT NOT NULL,
            \\  availability TEXT NOT NULL,
            \\  ts_wall INTEGER NOT NULL
            \\);
        );
    }

    pub fn insertBatterySample(self: *Db, sample: models.BatterySample) !void {
        const stmt = try self.prepare(
            \\INSERT INTO battery_samples (
            \\  ts_wall, ts_mono_ns, percent, ac_online, status, power_w, energy_now_wh, energy_full_wh, source, confidence
            \\) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer _ = c.sqlite3_finalize(stmt);

        try bindInt64(stmt, 1, sample.ts_wall);
        try bindInt64(stmt, 2, sample.ts_mono_ns);
        try bindDouble(stmt, 3, sample.percent);
        try bindInt(stmt, 4, if (sample.ac_online) 1 else 0);
        try bindText(stmt, 5, sample.status.label());
        if (sample.power_w) |value| try bindDouble(stmt, 6, value) else try bindNull(stmt, 6);
        if (sample.energy_now_wh) |value| try bindDouble(stmt, 7, value) else try bindNull(stmt, 7);
        if (sample.energy_full_wh) |value| try bindDouble(stmt, 8, value) else try bindNull(stmt, 8);
        try bindText(stmt, 9, sample.source);
        try bindText(stmt, 10, sample.confidence.label());
        try stepDone(stmt);
    }

    pub fn insertEvent(self: *Db, event: models.Event) !void {
        const stmt = try self.prepare(
            \\INSERT INTO events (ts_start, ts_end, kind, value, details)
            \\VALUES (?, ?, ?, ?, ?)
        );
        defer _ = c.sqlite3_finalize(stmt);

        try bindInt64(stmt, 1, event.ts_start);
        try bindInt64(stmt, 2, event.ts_end);
        try bindText(stmt, 3, event.kind);
        try bindText(stmt, 4, event.value);
        try bindText(stmt, 5, event.details);
        try stepDone(stmt);
    }

    pub fn replaceState(self: *Db, ts_wall: i64, items: []const models.StateSample) !void {
        try self.exec("DELETE FROM state_latest");
        for (items) |item| {
            const stmt = try self.prepare(
                \\INSERT INTO state_latest (key, section, value, availability, ts_wall)
                \\VALUES (?, ?, ?, ?, ?)
            );
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, item.key);
            try bindText(stmt, 2, item.section);
            try bindText(stmt, 3, item.value);
            try bindText(stmt, 4, item.availability.label());
            try bindInt64(stmt, 5, ts_wall);
            try stepDone(stmt);
        }
    }

    pub fn insertBucketLive(self: *Db, ts_wall: i64, key: []const u8, label: []const u8, watts: f64, score: f64, confidence: models.Confidence) !void {
        const stmt = try self.prepare(
            \\INSERT INTO bucket_live_samples (ts_wall, bucket_key, bucket_label, estimated_w, score, confidence)
            \\VALUES (?, ?, ?, ?, ?, ?)
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, ts_wall);
        try bindText(stmt, 2, key);
        try bindText(stmt, 3, label);
        try bindDouble(stmt, 4, watts);
        try bindDouble(stmt, 5, score);
        try bindText(stmt, 6, confidence.label());
        try stepDone(stmt);
    }

    pub fn insertProcessLive(self: *Db, ts_wall: i64, pid: i32, label: []const u8, bucket_label: []const u8, watts: f64, score: f64, confidence: models.Confidence) !void {
        const stmt = try self.prepare(
            \\INSERT INTO process_live_samples (ts_wall, pid, process_label, bucket_label, estimated_w, score, confidence)
            \\VALUES (?, ?, ?, ?, ?, ?, ?)
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, ts_wall);
        try bindInt(stmt, 2, pid);
        try bindText(stmt, 3, label);
        try bindText(stmt, 4, bucket_label);
        try bindDouble(stmt, 5, watts);
        try bindDouble(stmt, 6, score);
        try bindText(stmt, 7, confidence.label());
        try stepDone(stmt);
    }

    pub fn insertBucketImpact(self: *Db, ts_wall: i64, key: []const u8, label: []const u8, energy_wh: f64, battery_pct: f64, avg_w: f64, confidence: models.Confidence) !void {
        const stmt = try self.prepare(
            \\INSERT INTO bucket_impact_samples (ts_wall, bucket_key, bucket_label, estimated_energy_wh, estimated_battery_pct, estimated_avg_w, confidence)
            \\VALUES (?, ?, ?, ?, ?, ?, ?)
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, ts_wall);
        try bindText(stmt, 2, key);
        try bindText(stmt, 3, label);
        try bindDouble(stmt, 4, energy_wh);
        try bindDouble(stmt, 5, battery_pct);
        try bindDouble(stmt, 6, avg_w);
        try bindText(stmt, 7, confidence.label());
        try stepDone(stmt);
    }

    pub fn insertProcessImpact(self: *Db, ts_wall: i64, pid: i32, label: []const u8, bucket_label: []const u8, energy_wh: f64, battery_pct: f64, avg_w: f64, confidence: models.Confidence) !void {
        const stmt = try self.prepare(
            \\INSERT INTO process_impact_samples (ts_wall, pid, process_label, bucket_label, estimated_energy_wh, estimated_battery_pct, estimated_avg_w, confidence)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, ts_wall);
        try bindInt(stmt, 2, pid);
        try bindText(stmt, 3, label);
        try bindText(stmt, 4, bucket_label);
        try bindDouble(stmt, 5, energy_wh);
        try bindDouble(stmt, 6, battery_pct);
        try bindDouble(stmt, 7, avg_w);
        try bindText(stmt, 8, confidence.label());
        try stepDone(stmt);
    }

    pub fn latestBattery(self: *Db) !?models.BatterySnapshot {
        const stmt = try self.prepare(
            \\SELECT ts_wall, percent, ac_online, status, power_w, energy_now_wh, energy_full_wh, confidence
            \\FROM battery_samples
            \\ORDER BY ts_wall DESC
            \\LIMIT 1
        );
        defer _ = c.sqlite3_finalize(stmt);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;
        return .{
            .ts_wall = c.sqlite3_column_int64(stmt, 0),
            .percent = c.sqlite3_column_double(stmt, 1),
            .ac_online = c.sqlite3_column_int(stmt, 2) != 0,
            .status = statusFromDb(columnText(stmt, 3)),
            .power_w = if (c.sqlite3_column_type(stmt, 4) == c.SQLITE_NULL) null else c.sqlite3_column_double(stmt, 4),
            .energy_now_wh = if (c.sqlite3_column_type(stmt, 5) == c.SQLITE_NULL) null else c.sqlite3_column_double(stmt, 5),
            .energy_full_wh = if (c.sqlite3_column_type(stmt, 6) == c.SQLITE_NULL) null else c.sqlite3_column_double(stmt, 6),
            .confidence = confidenceFromDb(columnText(stmt, 7)),
        };
    }

    pub fn queryGraph(self: *Db, allocator: std.mem.Allocator, start_ts: i64, end_ts: i64) ![]models.GraphPoint {
        const stmt = try self.prepare(
            \\SELECT ts_wall, percent, ac_online, status, power_w
            \\FROM battery_samples
            \\WHERE ts_wall BETWEEN ? AND ?
            \\ORDER BY ts_wall ASC
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, start_ts);
        try bindInt64(stmt, 2, end_ts);

        var rows = std.ArrayList(models.GraphPoint).empty;
        errdefer rows.deinit(allocator);
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;
            try rows.append(allocator, .{
                .ts_wall = c.sqlite3_column_int64(stmt, 0),
                .percent = c.sqlite3_column_double(stmt, 1),
                .ac_online = c.sqlite3_column_int(stmt, 2) != 0,
                .status = statusFromDb(columnText(stmt, 3)),
                .power_w = if (c.sqlite3_column_type(stmt, 4) == c.SQLITE_NULL) null else c.sqlite3_column_double(stmt, 4),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    pub fn queryEvents(self: *Db, allocator: std.mem.Allocator, start_ts: i64, end_ts: i64) ![]models.Event {
        const stmt = try self.prepare(
            \\SELECT ts_start, ts_end, kind, value, details
            \\FROM events
            \\WHERE ts_end >= ? AND ts_start <= ?
            \\ORDER BY ts_start ASC
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, start_ts);
        try bindInt64(stmt, 2, end_ts);

        var rows = std.ArrayList(models.Event).empty;
        errdefer {
            for (rows.items) |row| {
                allocator.free(@constCast(row.kind));
                allocator.free(@constCast(row.value));
                allocator.free(@constCast(row.details));
            }
            rows.deinit(allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;
            try rows.append(allocator, .{
                .ts_start = c.sqlite3_column_int64(stmt, 0),
                .ts_end = c.sqlite3_column_int64(stmt, 1),
                .kind = try allocator.dupe(u8, columnText(stmt, 2)),
                .value = try allocator.dupe(u8, columnText(stmt, 3)),
                .details = try allocator.dupe(u8, columnText(stmt, 4)),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    pub fn queryImpactRows(self: *Db, allocator: std.mem.Allocator, start_ts: i64, end_ts: i64, processes: bool, limit: usize) ![]models.ImpactRow {
        const sql = if (processes) blk: {
            break :blk
                \\SELECT process_label, MAX(bucket_label), SUM(estimated_energy_wh), SUM(estimated_battery_pct), AVG(estimated_avg_w), MIN(confidence)
                \\FROM process_impact_samples
                \\WHERE ts_wall BETWEEN ? AND ?
                \\GROUP BY process_label
                \\ORDER BY SUM(estimated_energy_wh) DESC
                \\LIMIT ?
            ;
        } else blk: {
            break :blk
                \\SELECT bucket_label, bucket_key, SUM(estimated_energy_wh), SUM(estimated_battery_pct), AVG(estimated_avg_w), MIN(confidence)
                \\FROM bucket_impact_samples
                \\WHERE ts_wall BETWEEN ? AND ?
                \\GROUP BY bucket_key, bucket_label
                \\ORDER BY SUM(estimated_energy_wh) DESC
                \\LIMIT ?
            ;
        };

        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, start_ts);
        try bindInt64(stmt, 2, end_ts);
        try bindInt(stmt, 3, @as(c_int, @intCast(limit)));

        var rows = std.ArrayList(models.ImpactRow).empty;
        errdefer {
            for (rows.items) |*row| row.deinit(allocator);
            rows.deinit(allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;
            try rows.append(allocator, .{
                .label = try allocator.dupe(u8, columnText(stmt, 0)),
                .aux = try allocator.dupe(u8, columnText(stmt, 1)),
                .energy_wh = c.sqlite3_column_double(stmt, 2),
                .battery_pct = c.sqlite3_column_double(stmt, 3),
                .watts = c.sqlite3_column_double(stmt, 4),
                .confidence = confidenceFromDb(columnText(stmt, 5)),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    pub fn queryLiveRows(self: *Db, allocator: std.mem.Allocator, processes: bool, limit: usize) ![]models.ImpactRow {
        const sql = if (processes) blk: {
            break :blk
                \\SELECT process_label, MAX(bucket_label), AVG(estimated_w), 0.0, AVG(estimated_w), MIN(confidence)
                \\FROM process_live_samples
                \\WHERE ts_wall >= (SELECT COALESCE(MAX(ts_wall), 0) - 10 FROM process_live_samples)
                \\GROUP BY process_label
                \\ORDER BY AVG(estimated_w) DESC
                \\LIMIT ?
            ;
        } else blk: {
            break :blk
                \\SELECT bucket_label, bucket_key, AVG(estimated_w), 0.0, AVG(estimated_w), MIN(confidence)
                \\FROM bucket_live_samples
                \\WHERE ts_wall >= (SELECT COALESCE(MAX(ts_wall), 0) - 10 FROM bucket_live_samples)
                \\GROUP BY bucket_key, bucket_label
                \\ORDER BY AVG(estimated_w) DESC
                \\LIMIT ?
            ;
        };

        const stmt = try self.prepare(sql);
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt(stmt, 1, @as(c_int, @intCast(limit)));

        var rows = std.ArrayList(models.ImpactRow).empty;
        errdefer {
            for (rows.items) |*row| row.deinit(allocator);
            rows.deinit(allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;
            try rows.append(allocator, .{
                .label = try allocator.dupe(u8, columnText(stmt, 0)),
                .aux = try allocator.dupe(u8, columnText(stmt, 1)),
                .energy_wh = c.sqlite3_column_double(stmt, 2),
                .battery_pct = c.sqlite3_column_double(stmt, 3),
                .watts = c.sqlite3_column_double(stmt, 4),
                .confidence = confidenceFromDb(columnText(stmt, 5)),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    pub fn queryStateRows(self: *Db, allocator: std.mem.Allocator) ![]models.StateRow {
        const stmt = try self.prepare(
            \\SELECT section, key, value, availability
            \\FROM state_latest
            \\ORDER BY section, key
        );
        defer _ = c.sqlite3_finalize(stmt);

        var rows = std.ArrayList(models.StateRow).empty;
        errdefer {
            for (rows.items) |*row| row.deinit(allocator);
            rows.deinit(allocator);
        }

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStepFailed;
            try rows.append(allocator, .{
                .section = try allocator.dupe(u8, columnText(stmt, 0)),
                .key = try allocator.dupe(u8, columnText(stmt, 1)),
                .value = try allocator.dupe(u8, columnText(stmt, 2)),
                .availability = confidenceFromDb(columnText(stmt, 3)),
            });
        }
        return rows.toOwnedSlice(allocator);
    }

    pub fn prune(self: *Db, now_ts: i64) !void {
        const raw_cutoff = now_ts - (7 * 24 * 3600);
        try self.execFmt("DELETE FROM process_live_samples WHERE ts_wall < {d};", .{raw_cutoff});
        try self.execFmt("DELETE FROM bucket_live_samples WHERE ts_wall < {d};", .{raw_cutoff});

        const impact_cutoff = now_ts - (90 * 24 * 3600);
        try self.execFmt("DELETE FROM process_impact_samples WHERE ts_wall < {d};", .{impact_cutoff});
        try self.execFmt("DELETE FROM bucket_impact_samples WHERE ts_wall < {d};", .{impact_cutoff});
    }

    fn execFmt(self: *Db, comptime fmt: []const u8, args: anytype) !void {
        const sql = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(sql);
        try self.exec(sql);
    }

    fn exec(self: *Db, sql: []const u8) !void {
        const c_sql = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(c_sql);
        var err_msg: [*c]u8 = null;
        if (c.sqlite3_exec(self.handle, c_sql.ptr, null, null, &err_msg) != c.SQLITE_OK) {
            if (err_msg != null) {
                const msg = err_msg.?;
                defer c.sqlite3_free(msg);
                std.log.err("sqlite error: {s}", .{std.mem.span(msg)});
            }
            return error.SqliteExecFailed;
        }
    }

    fn prepare(self: *Db, sql: []const u8) !*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @as(c_int, @intCast(sql.len)), &stmt, null) != c.SQLITE_OK) {
            std.log.err("sqlite prepare failed: {s}; sql={s}", .{
                std.mem.span(c.sqlite3_errmsg(self.handle)),
                sql,
            });
            return error.SqlitePrepareFailed;
        }
        return stmt.?;
    }
};

fn bindInt(stmt: *c.sqlite3_stmt, index: c_int, value: c_int) !void {
    if (c.sqlite3_bind_int(stmt, index, value) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn bindInt64(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn bindDouble(stmt: *c.sqlite3_stmt, index: c_int, value: f64) !void {
    if (c.sqlite3_bind_double(stmt, index, value) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @as(c_int, @intCast(value.len)), null) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn bindNull(stmt: *c.sqlite3_stmt, index: c_int) !void {
    if (c.sqlite3_bind_null(stmt, index) != c.SQLITE_OK) return error.SqliteBindFailed;
}

fn stepDone(stmt: *c.sqlite3_stmt) !void {
    const rc = c.sqlite3_step(stmt);
    if (rc != c.SQLITE_DONE) return error.SqliteStepFailed;
}

fn columnText(stmt: *c.sqlite3_stmt, index: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, index) orelse return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

fn statusFromDb(raw: []const u8) models.BatteryStatus {
    return models.BatteryStatus.fromSysfs(raw);
}

fn confidenceFromDb(raw: []const u8) models.Confidence {
    if (std.mem.eql(u8, raw, "measured")) return .measured;
    if (std.mem.eql(u8, raw, "derived")) return .derived;
    if (std.mem.eql(u8, raw, "estimated")) return .estimated;
    return .unavailable;
}
