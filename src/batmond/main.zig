const std = @import("std");
const core = @import("core");

const State = struct {
    allocator: std.mem.Allocator,
    db: core.storage.Db,
    previous_battery: ?core.models.BatterySample = null,
    previous_processes: []core.models.ProcessCounters = &.{},
    score_accumulator: std.StringHashMap(BucketAccumulator),
    process_score_accumulator: std.StringHashMap(ProcessAccumulator),
    last_boottime_ns: ?i64 = null,
    last_mono_ns: ?i64 = null,
    last_state_refresh: i64 = 0,
    had_recent_sleep: bool = false,
    last_rate_pct_per_hour: ?f64 = null,

    fn deinit(self: *State) void {
        if (self.previous_processes.len > 0) core.models.freeProcessCountersSlice(self.allocator, self.previous_processes);
        var it = self.score_accumulator.iterator();
        while (it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
            self.allocator.free(entry.value_ptr.label);
        }
        self.score_accumulator.deinit();
        var process_it = self.process_score_accumulator.iterator();
        while (process_it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
            self.allocator.free(entry.value_ptr.bucket_label);
        }
        self.process_score_accumulator.deinit();
        self.db.close();
    }
};

const BucketAccumulator = struct {
    label: []u8,
    score: f64,
};

const ProcessAccumulator = struct {
    bucket_label: []u8,
    score: f64,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;

    var db_path = try defaultDatabasePath(allocator, init.environ);
    defer allocator.free(db_path);

    var args = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args.deinit();
    _ = args.next();

    var run_mode = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "run")) {
            run_mode = true;
        } else if (std.mem.eql(u8, arg, "--database-path")) {
            if (args.next()) |value| {
                allocator.free(db_path);
                db_path = try allocator.dupe(u8, value);
            } else {
                return error.MissingDatabasePath;
            }
        } else if (std.mem.eql(u8, arg, "sample-once")) {
            run_mode = false;
        }
    }

    try ensureParentDir(allocator, db_path);
    const db = try core.storage.Db.open(allocator, db_path, false);

    var state = State{
        .allocator = allocator,
        .db = db,
        .score_accumulator = std.StringHashMap(BucketAccumulator).init(allocator),
        .process_score_accumulator = std.StringHashMap(ProcessAccumulator).init(allocator),
    };
    defer state.deinit();

    try emitStartupGap(&state);

    if (!run_mode) {
        try sampleTick(&state, true);
        return;
    }

    var iteration: usize = 0;
    while (true) : (iteration += 1) {
        try sampleTick(&state, iteration % 5 == 0);
        try std.Io.sleep(std.Options.debug_io, std.Io.Duration.fromSeconds(1), .awake);
    }
}

fn sampleTick(state: *State, do_battery_sample: bool) !void {
    const clocks = try core.sensors.snapshotClocks();
    try detectSleep(state, clocks);

    const current_processes = try core.sensors.collectProcessCounters(state.allocator);

    if (state.previous_processes.len > 0) {
        const process_deltas = try core.sensors.diffProcesses(state.allocator, state.previous_processes, current_processes);
        defer core.models.freeProcessDeltaSlice(state.allocator, process_deltas);

        const bucket_deltas = try core.sensors.summarizeBuckets(state.allocator, process_deltas);
        defer core.models.freeBucketDeltaSlice(state.allocator, bucket_deltas);

        try writeLiveEstimates(state, clocks.wall_s, process_deltas, bucket_deltas);
        try accumulateBucketScores(state, bucket_deltas);
        try accumulateProcessScores(state, process_deltas);
    }

    if (state.previous_processes.len > 0) core.models.freeProcessCountersSlice(state.allocator, state.previous_processes);
    state.previous_processes = current_processes;

    if (do_battery_sample) {
        if (try core.sensors.collectBatterySample(state.allocator)) |sample| {
            try state.db.insertBatterySample(sample);
            try emitBatteryEvents(state, sample);
            try emitImpactSamples(state, sample);
            try maybeDetectAnomaly(state, sample);
            state.previous_battery = sample;
        }

        if (clocks.wall_s - state.last_state_refresh >= 60 or state.last_state_refresh == 0) {
            const state_rows = try core.sensors.collectStateSamples(state.allocator);
            defer core.models.freeStateSampleSlice(state.allocator, state_rows);
            try state.db.replaceState(clocks.wall_s, state_rows);
            state.last_state_refresh = clocks.wall_s;
        }

        try state.db.prune(clocks.wall_s);
    }
}

fn writeLiveEstimates(state: *State, ts_wall: i64, process_deltas: []const core.models.ProcessDelta, bucket_deltas: []const core.models.BucketDelta) !void {
    const live_power = if (state.previous_battery) |battery|
        battery.power_w orelse 0.0
    else
        0.0;

    var total_score: f64 = 0;
    for (bucket_deltas) |delta| total_score += delta.score;
    if (total_score <= 0 or live_power <= 0) return;

    for (bucket_deltas) |delta| {
        const watts = live_power * (delta.score / total_score);
        try state.db.insertBucketLive(ts_wall, delta.key, delta.label, watts, delta.score, .estimated);
    }
    for (process_deltas) |delta| {
        const watts = live_power * (delta.score / total_score);
        try state.db.insertProcessLive(ts_wall, delta.pid, delta.process_label, delta.bucket_label, watts, delta.score, .estimated);
    }
}

fn accumulateBucketScores(state: *State, bucket_deltas: []const core.models.BucketDelta) !void {
    for (bucket_deltas) |delta| {
        if (state.score_accumulator.getPtr(delta.key)) |entry| {
            entry.score += delta.score;
            continue;
        }
        try state.score_accumulator.put(try state.allocator.dupe(u8, delta.key), .{
            .label = try state.allocator.dupe(u8, delta.label),
            .score = delta.score,
        });
    }
}

fn accumulateProcessScores(state: *State, process_deltas: []const core.models.ProcessDelta) !void {
    for (process_deltas) |delta| {
        if (state.process_score_accumulator.getPtr(delta.process_label)) |entry| {
            entry.score += delta.score;
            continue;
        }
        try state.process_score_accumulator.put(try state.allocator.dupe(u8, delta.process_label), .{
            .bucket_label = try state.allocator.dupe(u8, delta.bucket_label),
            .score = delta.score,
        });
    }
}

fn emitBatteryEvents(state: *State, sample: core.models.BatterySample) !void {
    if (state.previous_battery) |prev| {
        if (prev.ac_online != sample.ac_online) {
            try state.db.insertEvent(.{
                .ts_start = sample.ts_wall,
                .ts_end = sample.ts_wall,
                .kind = "ac_change",
                .value = if (sample.ac_online) "connected" else "disconnected",
                .details = if (sample.ac_online) "external power connected" else "external power removed",
            });
        }
        if (prev.status != sample.status) {
            try state.db.insertEvent(.{
                .ts_start = sample.ts_wall,
                .ts_end = sample.ts_wall,
                .kind = "status_change",
                .value = sample.status.label(),
                .details = "battery status transition",
            });
        }
    }
}

fn emitImpactSamples(state: *State, sample: core.models.BatterySample) !void {
    const previous = state.previous_battery orelse {
        clearAccumulators(state);
        return;
    };

    const dt_s = sample.ts_wall - previous.ts_wall;
    if (dt_s <= 0) {
        clearAccumulators(state);
        return;
    }

    if (sample.status != .discharging or previous.status != .discharging) {
        clearAccumulators(state);
        return;
    }

    const energy_delta = deriveEnergyDeltaWh(previous, sample);
    if (energy_delta <= 0) {
        clearAccumulators(state);
        return;
    }

    var total_score: f64 = 0;
    var it_total = state.score_accumulator.iterator();
    while (it_total.next()) |entry| total_score += entry.value_ptr.score;

    var total_process_score: f64 = 0;
    var process_total = state.process_score_accumulator.iterator();
    while (process_total.next()) |entry| total_process_score += entry.value_ptr.score;

    const full_wh = sample.energy_full_wh orelse previous.energy_full_wh orelse 0;
    const avg_w = energy_delta / (@as(f64, @floatFromInt(dt_s)) / 3600.0);

    if (total_score <= 0) {
        const unattributed_pct = if (full_wh > 0) (energy_delta / full_wh) * 100.0 else 0.0;
        try state.db.insertBucketImpact(sample.ts_wall, "unattributed", "unattributed", energy_delta, unattributed_pct, avg_w, .estimated);
        clearAccumulators(state);
        return;
    }

    const attributable = energy_delta * 0.85;
    var it = state.score_accumulator.iterator();
    while (it.next()) |entry| {
        const share = entry.value_ptr.score / total_score;
        const wh = attributable * share;
        const pct = if (full_wh > 0) (wh / full_wh) * 100.0 else 0.0;
        try state.db.insertBucketImpact(sample.ts_wall, entry.key_ptr.*, entry.value_ptr.label, wh, pct, avg_w * share, .estimated);
    }

    if (total_process_score > 0) {
        var process_it = state.process_score_accumulator.iterator();
        while (process_it.next()) |entry| {
            const share = entry.value_ptr.score / total_process_score;
            const wh = attributable * share;
            const pct = if (full_wh > 0) (wh / full_wh) * 100.0 else 0.0;
            try state.db.insertProcessImpact(sample.ts_wall, 0, entry.key_ptr.*, entry.value_ptr.bucket_label, wh, pct, avg_w * share, .estimated);
        }
    }

    const unattributed_wh = energy_delta - attributable;
    const unattributed_pct = if (full_wh > 0) (unattributed_wh / full_wh) * 100.0 else 0.0;
    try state.db.insertBucketImpact(sample.ts_wall, "unattributed", "unattributed", unattributed_wh, unattributed_pct, avg_w * 0.15, .estimated);
    clearAccumulators(state);
}

fn maybeDetectAnomaly(state: *State, sample: core.models.BatterySample) !void {
    const prev = state.previous_battery orelse return;
    if (sample.status != .discharging or prev.status != .discharging) return;

    const dt_h = @as(f64, @floatFromInt(sample.ts_wall - prev.ts_wall)) / 3600.0;
    if (dt_h <= 0) return;
    const rate = (prev.percent - sample.percent) / dt_h;

    if (state.last_rate_pct_per_hour) |last_rate| {
        if (rate > 30.0 and rate > last_rate * 1.6) {
            const details = try std.fmt.allocPrint(state.allocator, "drain jumped from {d:.1}%/h to {d:.1}%/h", .{ last_rate, rate });
            defer state.allocator.free(details);
            try state.db.insertEvent(.{
                .ts_start = sample.ts_wall,
                .ts_end = sample.ts_wall,
                .kind = "anomaly",
                .value = "drain_spike",
                .details = details,
            });
        } else if (state.had_recent_sleep and rate > 18.0) {
            const details = try std.fmt.allocPrint(state.allocator, "high post-resume drain at {d:.1}%/h", .{rate});
            defer state.allocator.free(details);
            try state.db.insertEvent(.{
                .ts_start = sample.ts_wall,
                .ts_end = sample.ts_wall,
                .kind = "anomaly",
                .value = "post_resume_drain",
                .details = details,
            });
            state.had_recent_sleep = false;
        }
    }
    state.last_rate_pct_per_hour = rate;
}

fn deriveEnergyDeltaWh(previous: core.models.BatterySample, current: core.models.BatterySample) f64 {
    if (previous.energy_now_wh != null and current.energy_now_wh != null) {
        return @max(previous.energy_now_wh.? - current.energy_now_wh.?, 0.0);
    }
    if (previous.power_w) |power| {
        const dt_h = @as(f64, @floatFromInt(current.ts_wall - previous.ts_wall)) / 3600.0;
        return @max(power * dt_h, 0.0);
    }
    return 0;
}

fn detectSleep(state: *State, clocks: core.sensors.ClockSnapshot) !void {
    if (state.last_boottime_ns) |last_boot| {
        const prev_mono = state.last_mono_ns.?;
        const suspend_delta = (clocks.boottime_ns - last_boot) - (clocks.mono_ns - prev_mono);
        if (suspend_delta > 2 * std.time.ns_per_s) {
            const suspend_s = @divTrunc(suspend_delta, std.time.ns_per_s);
            try state.db.insertEvent(.{
                .ts_start = clocks.wall_s - suspend_s,
                .ts_end = clocks.wall_s,
                .kind = "sleep",
                .value = "suspend",
                .details = "detected from boottime/monotonic gap",
            });
            state.had_recent_sleep = true;
        }
    }
    state.last_boottime_ns = clocks.boottime_ns;
    state.last_mono_ns = clocks.mono_ns;
}

fn emitStartupGap(state: *State) !void {
    if (try state.db.latestBattery()) |latest| {
        const now_ts = (try core.sensors.snapshotClocks()).wall_s;
        if (now_ts - latest.ts_wall > 15) {
            const details = try std.fmt.allocPrint(state.allocator, "collector resumed after {d}s", .{now_ts - latest.ts_wall});
            defer state.allocator.free(details);
            try state.db.insertEvent(.{
                .ts_start = latest.ts_wall,
                .ts_end = now_ts,
                .kind = "collector_gap",
                .value = "gap",
                .details = details,
            });
        }
    }
}

fn clearAccumulators(state: *State) void {
    const new_map = std.StringHashMap(BucketAccumulator).init(state.allocator);
    var it = state.score_accumulator.iterator();
    while (it.next()) |entry| {
        state.allocator.free(@constCast(entry.key_ptr.*));
        state.allocator.free(entry.value_ptr.label);
    }
    state.score_accumulator.deinit();
    state.score_accumulator = new_map;

    const new_process_map = std.StringHashMap(ProcessAccumulator).init(state.allocator);
    var process_it = state.process_score_accumulator.iterator();
    while (process_it.next()) |entry| {
        state.allocator.free(@constCast(entry.key_ptr.*));
        state.allocator.free(entry.value_ptr.bucket_label);
    }
    state.process_score_accumulator.deinit();
    state.process_score_accumulator = new_process_map;
}

fn defaultDatabasePath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    if (try getEnvOwned(allocator, environ, "BATMON_DB_PATH")) |value| return value;
    if (try getEnvOwned(allocator, environ, "XDG_STATE_HOME")) |state_home| {
        defer allocator.free(state_home);
        return std.fmt.allocPrint(allocator, "{s}/batmon/batmon.db", .{state_home});
    }
    if (try getEnvOwned(allocator, environ, "HOME")) |home| {
        defer allocator.free(home);
        return std.fmt.allocPrint(allocator, "{s}/.local/state/batmon/batmon.db", .{home});
    }
    return allocator.dupe(u8, "batmon.db");
}

fn getEnvOwned(allocator: std.mem.Allocator, environ: std.process.Environ, key: []const u8) !?[]u8 {
    return environ.getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

fn ensureParentDir(allocator: std.mem.Allocator, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    try std.Io.Dir.cwd().createDirPath(std.Options.debug_io, parent);
    _ = allocator;
}

fn testDbPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

fn makeTestState(allocator: std.mem.Allocator, db_path: []const u8) !State {
    return .{
        .allocator = allocator,
        .db = try core.storage.Db.open(allocator, db_path, false),
        .score_accumulator = std.StringHashMap(BucketAccumulator).init(allocator),
        .process_score_accumulator = std.StringHashMap(ProcessAccumulator).init(allocator),
    };
}

fn freeEventsForTest(allocator: std.mem.Allocator, events: []core.models.Event) void {
    for (events) |event| {
        allocator.free(@constCast(event.kind));
        allocator.free(@constCast(event.value));
        allocator.free(@constCast(event.details));
    }
    allocator.free(events);
}

fn freeImpactRowsForTest(allocator: std.mem.Allocator, rows: []core.models.ImpactRow) void {
    for (rows) |*row| row.deinit(allocator);
    allocator.free(rows);
}

test "deriveEnergyDeltaWh falls back to power when battery only reports charge" {
    const previous: core.models.BatterySample = .{
        .ts_wall = 1_000,
        .ts_mono_ns = 0,
        .percent = 80.0,
        .ac_online = false,
        .status = .discharging,
        .power_w = 18.0,
        .energy_now_wh = null,
        .energy_full_wh = 50.0,
        .battery_count = 1,
        .source = "sysfs",
        .confidence = .derived,
    };
    const current: core.models.BatterySample = .{
        .ts_wall = 2_800,
        .ts_mono_ns = 0,
        .percent = 62.0,
        .ac_online = false,
        .status = .discharging,
        .power_w = null,
        .energy_now_wh = null,
        .energy_full_wh = 50.0,
        .battery_count = 1,
        .source = "sysfs",
        .confidence = .derived,
    };

    try std.testing.expectApproxEqRel(9.0, deriveEnergyDeltaWh(previous, current), 1e-9);
}

test "emitBatteryEvents records AC and status changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try testDbPath(allocator, &tmp.sub_path, "events.db");
    defer allocator.free(db_path);

    var state = try makeTestState(allocator, db_path);
    defer state.deinit();

    state.previous_battery = .{
        .ts_wall = 1_000,
        .ts_mono_ns = 0,
        .percent = 70.0,
        .ac_online = false,
        .status = .discharging,
        .power_w = 10.0,
        .energy_now_wh = 35.0,
        .energy_full_wh = 50.0,
        .battery_count = 1,
        .source = "sysfs",
        .confidence = .measured,
    };

    try emitBatteryEvents(&state, .{
        .ts_wall = 1_060,
        .ts_mono_ns = 0,
        .percent = 71.0,
        .ac_online = true,
        .status = .charging,
        .power_w = 20.0,
        .energy_now_wh = 35.5,
        .energy_full_wh = 50.0,
        .battery_count = 1,
        .source = "sysfs",
        .confidence = .measured,
    });

    const events = try state.db.queryEvents(allocator, 0, 2_000);
    defer freeEventsForTest(allocator, events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    var saw_ac_change = false;
    var saw_status_change = false;
    for (events) |event| {
        if (std.mem.eql(u8, event.kind, "ac_change")) saw_ac_change = true;
        if (std.mem.eql(u8, event.kind, "status_change")) saw_status_change = true;
    }
    try std.testing.expect(saw_ac_change);
    try std.testing.expect(saw_status_change);
}

test "emitImpactSamples writes unattributed discharge when no scores exist" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try testDbPath(allocator, &tmp.sub_path, "impact.db");
    defer allocator.free(db_path);

    var state = try makeTestState(allocator, db_path);
    defer state.deinit();

    state.previous_battery = .{
        .ts_wall = 1_000,
        .ts_mono_ns = 0,
        .percent = 80.0,
        .ac_online = false,
        .status = .discharging,
        .power_w = 10.0,
        .energy_now_wh = 40.0,
        .energy_full_wh = 50.0,
        .battery_count = 1,
        .source = "sysfs",
        .confidence = .measured,
    };

    try emitImpactSamples(&state, .{
        .ts_wall = 4_600,
        .ts_mono_ns = 0,
        .percent = 70.0,
        .ac_online = false,
        .status = .discharging,
        .power_w = 10.0,
        .energy_now_wh = 35.0,
        .energy_full_wh = 50.0,
        .battery_count = 1,
        .source = "sysfs",
        .confidence = .measured,
    });

    const rows = try state.db.queryImpactRows(allocator, 0, 10_000, false, 10);
    defer freeImpactRowsForTest(allocator, rows);

    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("unattributed", rows[0].label);
    try std.testing.expectApproxEqRel(5.0, rows[0].energy_wh, 1e-9);
    try std.testing.expectApproxEqRel(10.0, rows[0].battery_pct, 1e-9);
}

test "detectSleep records a sleep event from boottime drift" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try testDbPath(allocator, &tmp.sub_path, "sleep.db");
    defer allocator.free(db_path);

    var state = try makeTestState(allocator, db_path);
    defer state.deinit();
    state.last_boottime_ns = 100 * std.time.ns_per_s;
    state.last_mono_ns = 100 * std.time.ns_per_s;

    try detectSleep(&state, .{
        .wall_s = 200,
        .mono_ns = 105 * std.time.ns_per_s,
        .boottime_ns = 135 * std.time.ns_per_s,
    });

    const events = try state.db.queryEvents(allocator, 0, 500);
    defer freeEventsForTest(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("sleep", events[0].kind);
    try std.testing.expectEqual(@as(i64, 170), events[0].ts_start);
    try std.testing.expectEqual(@as(i64, 200), events[0].ts_end);
}

test "maybeDetectAnomaly records a drain spike" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try testDbPath(allocator, &tmp.sub_path, "anomaly.db");
    defer allocator.free(db_path);

    var state = try makeTestState(allocator, db_path);
    defer state.deinit();
    state.previous_battery = .{
        .ts_wall = 1_000,
        .ts_mono_ns = 0,
        .percent = 90.0,
        .ac_online = false,
        .status = .discharging,
        .power_w = 8.0,
        .energy_now_wh = 45.0,
        .energy_full_wh = 50.0,
        .battery_count = 1,
        .source = "sysfs",
        .confidence = .measured,
    };
    state.last_rate_pct_per_hour = 8.0;

    try maybeDetectAnomaly(&state, .{
        .ts_wall = 4_600,
        .ts_mono_ns = 0,
        .percent = 50.0,
        .ac_online = false,
        .status = .discharging,
        .power_w = 25.0,
        .energy_now_wh = 25.0,
        .energy_full_wh = 50.0,
        .battery_count = 1,
        .source = "sysfs",
        .confidence = .measured,
    });

    const events = try state.db.queryEvents(allocator, 0, 10_000);
    defer freeEventsForTest(allocator, events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("anomaly", events[0].kind);
    try std.testing.expectEqualStrings("drain_spike", events[0].value);
}
