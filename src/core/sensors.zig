const std = @import("std");
const models = @import("models.zig");
const bucketing = @import("bucketing.zig");

const std_io = std.Options.debug_io;

pub const ClockSnapshot = struct {
    wall_s: i64,
    mono_ns: i64,
    boottime_ns: i64,
};

pub fn snapshotClocks() !ClockSnapshot {
    return .{
        .wall_s = std.Io.Clock.real.now(std_io).toSeconds(),
        .mono_ns = @intCast(std.Io.Clock.awake.now(std_io).toNanoseconds()),
        .boottime_ns = @intCast(std.Io.Clock.boot.now(std_io).toNanoseconds()),
    };
}

fn shouldInspectSysfsEntry(kind: std.Io.File.Kind) bool {
    return switch (kind) {
        .named_pipe, .unix_domain_socket, .door, .event_port, .whiteout => false,
        else => true,
    };
}

pub fn collectBatterySample(allocator: std.mem.Allocator) !?models.BatterySample {
    const clocks = try snapshotClocks();
    var dir = try openDirAbsolute("/sys/class/power_supply", true);
    defer dir.close(std_io);

    var it = dir.iterate();
    var battery_count: u32 = 0;
    var total_percent: f64 = 0;
    var total_full: f64 = 0;
    var total_now: f64 = 0;
    var total_power: f64 = 0;
    var percent_weight: f64 = 0;
    var ac_online = false;
    var status = models.BatteryStatus.unknown;
    var confidence: models.Confidence = .measured;

    while (try it.next(std_io)) |entry| {
        if (!shouldInspectSysfsEntry(entry.kind)) continue;

        const type_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/type", .{entry.name});
        defer allocator.free(type_path);
        const maybe_type = try readOptionalTrimmed(allocator, type_path);
        if (maybe_type == null) continue;
        defer allocator.free(maybe_type.?);

        const supply_type = maybe_type.?;
        if (std.mem.eql(u8, supply_type, "Battery")) {
            battery_count += 1;

            var sample = try readBatteryDirectory(allocator, entry.name);
            defer sample.deinit(allocator);

            if (sample.energy_full_wh) |full| {
                total_full += full;
                percent_weight += full;
            }
            if (sample.energy_now_wh) |now| total_now += now;
            if (sample.power_w) |power| total_power += power;

            if (sample.energy_full_wh != null and sample.energy_now_wh != null) {
                total_percent += sample.percent * sample.energy_full_wh.?;
            } else {
                total_percent += sample.percent;
            }

            if (sample.ac_online) ac_online = true;
            if (status == .unknown or sample.status == .discharging or sample.status == .charging) {
                status = sample.status;
            }
            if (sample.confidence == .derived and confidence == .measured) confidence = .derived;
        } else if (std.mem.eql(u8, supply_type, "Mains") or std.mem.eql(u8, supply_type, "USB") or std.mem.eql(u8, supply_type, "USB_C")) {
            const online_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/online", .{entry.name});
            defer allocator.free(online_path);
            if (try readIntFile(online_path)) |online| {
                if (online > 0) ac_online = true;
            }
        }
    }

    if (battery_count == 0) return null;

    const percent = if (percent_weight > 0)
        total_percent / percent_weight
    else
        total_percent / @as(f64, @floatFromInt(battery_count));

    return models.BatterySample{
        .ts_wall = clocks.wall_s,
        .ts_mono_ns = clocks.mono_ns,
        .percent = std.math.clamp(percent, 0, 100),
        .ac_online = ac_online,
        .status = status,
        .power_w = if (total_power > 0) total_power else null,
        .energy_now_wh = if (total_now > 0) total_now else null,
        .energy_full_wh = if (total_full > 0) total_full else null,
        .battery_count = battery_count,
        .source = "sysfs",
        .confidence = confidence,
    };
}

const SingleBattery = struct {
    percent: f64,
    ac_online: bool,
    status: models.BatteryStatus,
    power_w: ?f64,
    energy_now_wh: ?f64,
    energy_full_wh: ?f64,
    confidence: models.Confidence,

    pub fn deinit(_: *SingleBattery, _: std.mem.Allocator) void {}
};

fn readBatteryDirectory(allocator: std.mem.Allocator, name: []const u8) !SingleBattery {
    const status_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/status", .{name});
    defer allocator.free(status_path);
    const raw_status = (try readOptionalTrimmed(allocator, status_path)) orelse try allocator.dupe(u8, "Unknown");
    defer allocator.free(raw_status);

    const capacity_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/capacity", .{name});
    defer allocator.free(capacity_path);

    const energy_now_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/energy_now", .{name});
    defer allocator.free(energy_now_path);
    const energy_full_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/energy_full", .{name});
    defer allocator.free(energy_full_path);
    const charge_now_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/charge_now", .{name});
    defer allocator.free(charge_now_path);
    const charge_full_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/charge_full", .{name});
    defer allocator.free(charge_full_path);
    const voltage_now_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/voltage_now", .{name});
    defer allocator.free(voltage_now_path);
    const power_now_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/power_now", .{name});
    defer allocator.free(power_now_path);
    const current_now_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/current_now", .{name});
    defer allocator.free(current_now_path);

    const energy_now_raw = try readIntFile(energy_now_path);
    const energy_full_raw = try readIntFile(energy_full_path);
    const charge_now_raw = try readIntFile(charge_now_path);
    const charge_full_raw = try readIntFile(charge_full_path);
    const voltage_now_raw = try readIntFile(voltage_now_path);
    const power_now_raw = try readIntFile(power_now_path);
    const current_now_raw = try readIntFile(current_now_path);
    const capacity_raw = try readIntFile(capacity_path);
    var used_derived_metric = false;

    const energy_now_wh = if (energy_now_raw) |value|
        microUnitToBase(value)
    else if (charge_now_raw != null and voltage_now_raw != null) blk: {
        used_derived_metric = true;
        break :blk chargeMicroAhToWh(charge_now_raw.?, voltage_now_raw.?);
    }
    else
        null;

    const energy_full_wh = if (energy_full_raw) |value|
        microUnitToBase(value)
    else if (charge_full_raw != null and voltage_now_raw != null) blk: {
        used_derived_metric = true;
        break :blk chargeMicroAhToWh(charge_full_raw.?, voltage_now_raw.?);
    }
    else
        null;

    const power_w = if (power_now_raw) |value|
        microUnitToBase(value)
    else if (current_now_raw != null and voltage_now_raw != null) blk: {
        used_derived_metric = true;
        break :blk currentVoltageToW(current_now_raw.?, voltage_now_raw.?);
    }
    else
        null;

    const confidence = batteryConfidence(energy_now_wh != null, used_derived_metric);

    const percent = if (capacity_raw) |value|
        @as(f64, @floatFromInt(value))
    else if (energy_now_wh != null and energy_full_wh != null and energy_full_wh.? > 0)
        (energy_now_wh.? / energy_full_wh.?) * 100.0
    else
        0;

    return .{
        .percent = percent,
        .ac_online = false,
        .status = models.BatteryStatus.fromSysfs(raw_status),
        .power_w = power_w,
        .energy_now_wh = energy_now_wh,
        .energy_full_wh = energy_full_wh,
        .confidence = confidence,
    };
}

pub fn collectStateSamples(allocator: std.mem.Allocator) ![]models.StateSample {
    var list = std.ArrayList(models.StateSample).empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    try appendOptionalFile(allocator, &list, "Configured state", "platform_profile", "/sys/firmware/acpi/platform_profile");
    try appendBacklight(allocator, &list);
    try appendCpuPolicies(allocator, &list);
    try appendRfkill(allocator, &list);
    try appendBatteryHealth(allocator, &list);
    try appendRuntimePmSummary(allocator, &list);

    return list.toOwnedSlice(allocator);
}

pub fn collectProcessCounters(allocator: std.mem.Allocator) ![]models.ProcessCounters {
    var proc_dir = try openDirAbsolute("/proc", true);
    defer proc_dir.close(std_io);

    var list = std.ArrayList(models.ProcessCounters).empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    var it = proc_dir.iterate();
    while (try it.next(std_io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!isNumeric(entry.name)) continue;

        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        const maybe_proc = try readProcCounters(allocator, pid);
        if (maybe_proc) |proc| try list.append(allocator, proc);
    }

    return list.toOwnedSlice(allocator);
}

pub fn diffProcesses(allocator: std.mem.Allocator, previous: []const models.ProcessCounters, current: []const models.ProcessCounters) ![]models.ProcessDelta {
    var index = std.AutoHashMap(models.ProcessKey, usize).init(allocator);
    defer index.deinit();

    for (previous, 0..) |proc, i| {
        try index.put(.{ .pid = proc.pid, .start_ticks = proc.start_ticks }, i);
    }

    var deltas = std.ArrayList(models.ProcessDelta).empty;
    errdefer {
        for (deltas.items) |*item| item.deinit(allocator);
        deltas.deinit(allocator);
    }

    for (current) |proc| {
        const prev_idx = index.get(.{ .pid = proc.pid, .start_ticks = proc.start_ticks }) orelse continue;
        const prev = previous[prev_idx];

        const cpu_delta = proc.cpu_ticks -| prev.cpu_ticks;
        const read_delta = proc.read_bytes -| prev.read_bytes;
        const write_delta = proc.write_bytes -| prev.write_bytes;
        if (cpu_delta == 0 and read_delta == 0 and write_delta == 0) continue;

        var bucket = try bucketing.derive(allocator, proc.comm, proc.exe, proc.cgroup_path);
        defer bucket.deinit(allocator);

        const process_label = try allocator.dupe(u8, bucket.process_label);
        const bucket_key = try allocator.dupe(u8, bucket.key);
        const bucket_label = try allocator.dupe(u8, bucket.label);

        const cpu_score = @as(f64, @floatFromInt(cpu_delta));
        const io_score = (@as(f64, @floatFromInt(read_delta + write_delta)) / (1024.0 * 1024.0)) * 10.0;
        const score = @max(cpu_score + io_score, 0.001);

        try deltas.append(allocator, .{
            .pid = proc.pid,
            .start_ticks = proc.start_ticks,
            .cpu_ticks_delta = cpu_delta,
            .read_bytes_delta = read_delta,
            .write_bytes_delta = write_delta,
            .score = score,
            .process_label = process_label,
            .bucket_key = bucket_key,
            .bucket_label = bucket_label,
        });
    }

    return deltas.toOwnedSlice(allocator);
}

pub fn summarizeBuckets(allocator: std.mem.Allocator, deltas: []const models.ProcessDelta) ![]models.BucketDelta {
    var map = std.StringHashMap(usize).init(allocator);
    defer map.deinit();

    var buckets = std.ArrayList(models.BucketDelta).empty;
    errdefer {
        for (buckets.items) |*bucket| bucket.deinit(allocator);
        buckets.deinit(allocator);
    }

    for (deltas) |delta| {
        if (map.get(delta.bucket_key)) |idx| {
            buckets.items[idx].cpu_ticks_delta += delta.cpu_ticks_delta;
            buckets.items[idx].read_bytes_delta += delta.read_bytes_delta;
            buckets.items[idx].write_bytes_delta += delta.write_bytes_delta;
            buckets.items[idx].score += delta.score;
            continue;
        }

        try buckets.append(allocator, .{
            .key = try allocator.dupe(u8, delta.bucket_key),
            .label = try allocator.dupe(u8, delta.bucket_label),
            .cpu_ticks_delta = delta.cpu_ticks_delta,
            .read_bytes_delta = delta.read_bytes_delta,
            .write_bytes_delta = delta.write_bytes_delta,
            .score = delta.score,
        });
        try map.put(buckets.items[buckets.items.len - 1].key, buckets.items.len - 1);
    }

    return buckets.toOwnedSlice(allocator);
}

fn appendOptionalFile(allocator: std.mem.Allocator, list: *std.ArrayList(models.StateSample), section: []const u8, key: []const u8, path: []const u8) !void {
    const maybe_value = try readOptionalTrimmed(allocator, path);
    if (maybe_value) |value| {
        defer allocator.free(value);
        try list.append(allocator, .{
            .section = try allocator.dupe(u8, section),
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
            .availability = .measured,
        });
    } else {
        try list.append(allocator, .{
            .section = try allocator.dupe(u8, section),
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, "unavailable"),
            .availability = .unavailable,
        });
    }
}

fn appendBacklight(allocator: std.mem.Allocator, list: *std.ArrayList(models.StateSample)) !void {
    var dir = openDirAbsolute("/sys/class/backlight", true) catch return;
    defer dir.close(std_io);

    var it = dir.iterate();
    if (try it.next(std_io)) |entry| {
        if (entry.kind != .directory) return;
        const brightness_path = try std.fmt.allocPrint(allocator, "/sys/class/backlight/{s}/brightness", .{entry.name});
        defer allocator.free(brightness_path);
        const max_path = try std.fmt.allocPrint(allocator, "/sys/class/backlight/{s}/max_brightness", .{entry.name});
        defer allocator.free(max_path);

        const current = (try readIntFile(brightness_path)) orelse return;
        const max = (try readIntFile(max_path)) orelse return;
        const pct = if (max > 0) (@as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(max))) * 100.0 else 0;
        const value = try std.fmt.allocPrint(allocator, "{d:.0}% ({d}/{d})", .{ pct, current, max });
        defer allocator.free(value);
        try list.append(allocator, .{
            .section = try allocator.dupe(u8, "Measured now"),
            .key = try allocator.dupe(u8, "brightness"),
            .value = try allocator.dupe(u8, value),
            .availability = .measured,
        });
    }
}

fn appendCpuPolicies(allocator: std.mem.Allocator, list: *std.ArrayList(models.StateSample)) !void {
    var dir = openDirAbsolute("/sys/devices/system/cpu/cpufreq", true) catch return;
    defer dir.close(std_io);
    var it = dir.iterate();
    while (try it.next(std_io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, "policy")) continue;

        const governor_path = try std.fmt.allocPrint(allocator, "/sys/devices/system/cpu/cpufreq/{s}/scaling_governor", .{entry.name});
        defer allocator.free(governor_path);
        const driver_path = try std.fmt.allocPrint(allocator, "/sys/devices/system/cpu/cpufreq/{s}/scaling_driver", .{entry.name});
        defer allocator.free(driver_path);
        const epp_path = try std.fmt.allocPrint(allocator, "/sys/devices/system/cpu/cpufreq/{s}/energy_performance_preference", .{entry.name});
        defer allocator.free(epp_path);

        try appendOptionalFile(allocator, list, "Configured state", "cpu_governor", governor_path);
        try appendOptionalFile(allocator, list, "Configured state", "cpu_driver", driver_path);
        try appendOptionalFile(allocator, list, "Configured state", "cpu_epp", epp_path);
        break;
    }
}

fn appendRfkill(allocator: std.mem.Allocator, list: *std.ArrayList(models.StateSample)) !void {
    var dir = openDirAbsolute("/sys/class/rfkill", true) catch return;
    defer dir.close(std_io);
    var it = dir.iterate();

    var total: usize = 0;
    var blocked: usize = 0;
    while (try it.next(std_io)) |entry| {
        if (entry.kind != .directory) continue;
        total += 1;
        const soft_path = try std.fmt.allocPrint(allocator, "/sys/class/rfkill/{s}/soft", .{entry.name});
        defer allocator.free(soft_path);
        if (try readIntFile(soft_path)) |value| {
            if (value != 0) blocked += 1;
        }
    }

    const value = try std.fmt.allocPrint(allocator, "{d} radios, {d} blocked", .{ total, blocked });
    defer allocator.free(value);
    try list.append(allocator, .{
        .section = try allocator.dupe(u8, "Configured state"),
        .key = try allocator.dupe(u8, "rfkill"),
        .value = try allocator.dupe(u8, value),
        .availability = .measured,
    });
}

fn appendBatteryHealth(allocator: std.mem.Allocator, list: *std.ArrayList(models.StateSample)) !void {
    var dir = openDirAbsolute("/sys/class/power_supply", true) catch return;
    defer dir.close(std_io);
    var it = dir.iterate();
    while (try it.next(std_io)) |entry| {
        if (!shouldInspectSysfsEntry(entry.kind)) continue;

        const type_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/type", .{entry.name});
        defer allocator.free(type_path);
        const raw_type = (try readOptionalTrimmed(allocator, type_path)) orelse continue;
        defer allocator.free(raw_type);
        if (!std.mem.eql(u8, raw_type, "Battery")) continue;

        const full_design_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/energy_full_design", .{entry.name});
        defer allocator.free(full_design_path);
        const full_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/energy_full", .{entry.name});
        defer allocator.free(full_path);
        const charge_full_design_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/charge_full_design", .{entry.name});
        defer allocator.free(charge_full_design_path);
        const charge_full_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/charge_full", .{entry.name});
        defer allocator.free(charge_full_path);
        const cycle_path = try std.fmt.allocPrint(allocator, "/sys/class/power_supply/{s}/cycle_count", .{entry.name});
        defer allocator.free(cycle_path);

        if (batteryHealthPercent(
            try readIntFile(full_design_path),
            try readIntFile(full_path),
            try readIntFile(charge_full_design_path),
            try readIntFile(charge_full_path),
        )) |health| {
            const value = try std.fmt.allocPrint(allocator, "{d:.1}%", .{health});
            defer allocator.free(value);
            try list.append(allocator, .{
                .section = try allocator.dupe(u8, "Configured state"),
                .key = try allocator.dupe(u8, "battery_health"),
                .value = try allocator.dupe(u8, value),
                .availability = .measured,
            });
        }

        if (try readIntFile(cycle_path)) |cycles| {
            const value = try std.fmt.allocPrint(allocator, "{d}", .{cycles});
            defer allocator.free(value);
            try list.append(allocator, .{
                .section = try allocator.dupe(u8, "Configured state"),
                .key = try allocator.dupe(u8, "cycle_count"),
                .value = try allocator.dupe(u8, value),
                .availability = .measured,
            });
        }
        break;
    }
}

fn appendRuntimePmSummary(allocator: std.mem.Allocator, list: *std.ArrayList(models.StateSample)) !void {
    var buses = openDirAbsolute("/sys/bus", true) catch return;
    defer buses.close(std_io);
    var bus_iter = buses.iterate();

    var auto_count: usize = 0;
    var on_count: usize = 0;
    while (try bus_iter.next(std_io)) |entry| {
        if (entry.kind != .directory) continue;
        const device_dir_path = try std.fmt.allocPrint(allocator, "/sys/bus/{s}/devices", .{entry.name});
        defer allocator.free(device_dir_path);
        var devices = openDirAbsolute(device_dir_path, true) catch continue;
        defer devices.close(std_io);

        var dev_iter = devices.iterate();
        while (try dev_iter.next(std_io)) |device| {
            if (device.kind != .sym_link and device.kind != .directory) continue;
            const control_path = try std.fmt.allocPrint(allocator, "{s}/{s}/power/control", .{ device_dir_path, device.name });
            defer allocator.free(control_path);
            const raw = (try readOptionalTrimmed(allocator, control_path)) orelse continue;
            defer allocator.free(raw);
            if (std.mem.eql(u8, raw, "auto")) auto_count += 1 else if (std.mem.eql(u8, raw, "on")) on_count += 1;
        }
    }

    const value = try std.fmt.allocPrint(allocator, "auto={d}, on={d}", .{ auto_count, on_count });
    defer allocator.free(value);
    try list.append(allocator, .{
        .section = try allocator.dupe(u8, "Configured state"),
        .key = try allocator.dupe(u8, "runtime_pm"),
        .value = try allocator.dupe(u8, value),
        .availability = .measured,
    });
}

fn readProcCounters(allocator: std.mem.Allocator, pid: i32) !?models.ProcessCounters {
    const stat_path = try std.fmt.allocPrint(allocator, "/proc/{d}/stat", .{pid});
    defer allocator.free(stat_path);
    const raw_stat = readFileAlloc(allocator, stat_path, 8192) catch return null;
    defer allocator.free(raw_stat);

    const proc_stat = parseProcStat(raw_stat) catch return null;

    const io_path = try std.fmt.allocPrint(allocator, "/proc/{d}/io", .{pid});
    defer allocator.free(io_path);
    const io_bytes = readProcIo(allocator, io_path) catch ProcIo{ .read = 0, .write = 0 };

    const exe_path = try std.fmt.allocPrint(allocator, "/proc/{d}/exe", .{pid});
    defer allocator.free(exe_path);
    const exe = readLinkAlloc(allocator, exe_path, 4096) catch try allocator.dupe(u8, proc_stat.comm);

    const cgroup_path = try std.fmt.allocPrint(allocator, "/proc/{d}/cgroup", .{pid});
    defer allocator.free(cgroup_path);
    const cgroup = try readProcCgroup(allocator, cgroup_path);

    return .{
        .pid = pid,
        .start_ticks = proc_stat.start_ticks,
        .ppid = proc_stat.ppid,
        .cpu_ticks = proc_stat.cpu_ticks,
        .read_bytes = io_bytes.read,
        .write_bytes = io_bytes.write,
        .rss_kib = proc_stat.rss_kib,
        .comm = try allocator.dupe(u8, proc_stat.comm),
        .exe = exe,
        .cgroup_path = cgroup,
    };
}

const ParsedProcStat = struct {
    comm: []const u8,
    ppid: i32,
    cpu_ticks: u64,
    start_ticks: u64,
    rss_kib: u64,
};

fn parseProcStat(raw: []const u8) !ParsedProcStat {
    const lparen = std.mem.indexOfScalar(u8, raw, '(') orelse return error.InvalidProcStat;
    const rparen = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return error.InvalidProcStat;
    const comm = raw[lparen + 1 .. rparen];

    const rest = raw[rparen + 2 ..];
    var fields = std.mem.tokenizeAny(u8, rest, " \n");

    var values: [32][]const u8 = undefined;
    var count: usize = 0;
    while (fields.next()) |field| : (count += 1) {
        if (count >= values.len) break;
        values[count] = field;
    }
    if (count < 22) return error.InvalidProcStat;

    const ppid = try std.fmt.parseInt(i32, values[1], 10);
    const utime = try std.fmt.parseInt(u64, values[11], 10);
    const stime = try std.fmt.parseInt(u64, values[12], 10);
    const start_ticks = try std.fmt.parseInt(u64, values[19], 10);
    const rss_pages = try std.fmt.parseInt(i64, values[21], 10);

    return .{
        .comm = comm,
        .ppid = ppid,
        .cpu_ticks = utime + stime,
        .start_ticks = start_ticks,
        .rss_kib = if (rss_pages > 0) @as(u64, @intCast(rss_pages * 4)) else 0,
    };
}

const ProcIo = struct {
    read: u64,
    write: u64,
};

fn readProcIo(allocator: std.mem.Allocator, path: []const u8) !ProcIo {
    const raw = try readFileAlloc(allocator, path, 4096);
    defer allocator.free(raw);
    var lines = std.mem.tokenizeAny(u8, raw, "\n");
    var result = ProcIo{ .read = 0, .write = 0 };
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "read_bytes:")) {
            result.read = try std.fmt.parseInt(u64, std.mem.trim(u8, line["read_bytes:".len..], " "), 10);
        } else if (std.mem.startsWith(u8, line, "write_bytes:")) {
            result.write = try std.fmt.parseInt(u64, std.mem.trim(u8, line["write_bytes:".len..], " "), 10);
        }
    }
    return result;
}

fn readProcCgroup(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const raw = readFileAlloc(allocator, path, 4096) catch return allocator.dupe(u8, "");
    defer allocator.free(raw);
    var lines = std.mem.tokenizeAny(u8, raw, "\n");
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, ':');
        _ = parts.next();
        _ = parts.next();
        if (parts.next()) |path_part| return allocator.dupe(u8, path_part);
    }
    return allocator.dupe(u8, "");
}

fn readOptionalTrimmed(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const raw = readFileAlloc(allocator, path, 4096) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.NotDir => return null,
        else => return err,
    };
    defer allocator.free(raw);
    return try allocator.dupe(u8, std.mem.trim(u8, raw, " \n\t"));
}

fn readIntFile(path: []const u8) !?i64 {
    const raw = readFileAlloc(std.heap.page_allocator, path, 256) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied, error.NotDir => return null,
        else => return err,
    };
    defer std.heap.page_allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \n\t");
    if (trimmed.len == 0) return null;
    return try std.fmt.parseInt(i64, trimmed, 10);
}

fn microUnitToBase(value: i64) f64 {
    return @as(f64, @floatFromInt(value)) / 1_000_000.0;
}

fn ratioPercent(current: i64, design: i64) ?f64 {
    if (current < 0 or design <= 0) return null;
    return (@as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(design))) * 100.0;
}

fn batteryHealthPercent(
    energy_full_design_raw: ?i64,
    energy_full_raw: ?i64,
    charge_full_design_raw: ?i64,
    charge_full_raw: ?i64,
) ?f64 {
    if (energy_full_raw) |full| {
        if (energy_full_design_raw) |design| {
            if (ratioPercent(full, design)) |health| return health;
        }
    }
    if (charge_full_raw) |full| {
        if (charge_full_design_raw) |design| {
            if (ratioPercent(full, design)) |health| return health;
        }
    }
    return null;
}

fn batteryConfidence(has_energy_now: bool, used_derived_metric: bool) models.Confidence {
    if (!has_energy_now or used_derived_metric) return .derived;
    return .measured;
}

fn chargeMicroAhToWh(charge_uah: i64, voltage_uv: i64) f64 {
    const ah = @as(f64, @floatFromInt(charge_uah)) / 1_000_000.0;
    const v = @as(f64, @floatFromInt(voltage_uv)) / 1_000_000.0;
    return ah * v;
}

fn currentVoltageToW(current_ua: i64, voltage_uv: i64) f64 {
    const a = @as(f64, @floatFromInt(current_ua)) / 1_000_000.0;
    const v = @as(f64, @floatFromInt(voltage_uv)) / 1_000_000.0;
    return a * v;
}

fn isNumeric(text: []const u8) bool {
    for (text) |char| {
        if (char < '0' or char > '9') return false;
    }
    return text.len > 0;
}

fn openDirAbsolute(path: []const u8, iterate: bool) !std.Io.Dir {
    return std.Io.Dir.openDirAbsolute(std_io, path, .{ .iterate = iterate });
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std_io, path, allocator, .limited(limit));
}

fn readLinkAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var buffer = try allocator.alloc(u8, max_bytes);
    defer allocator.free(buffer);
    const len = try std.Io.Dir.readLinkAbsolute(std_io, path, buffer);
    return allocator.dupe(u8, buffer[0..len]);
}

test "power supply sysfs scan accepts symlinked entries" {
    try std.testing.expect(shouldInspectSysfsEntry(.sym_link));
    try std.testing.expect(shouldInspectSysfsEntry(.directory));
    try std.testing.expect(shouldInspectSysfsEntry(.unknown));
    try std.testing.expect(shouldInspectSysfsEntry(.file));
    try std.testing.expect(!shouldInspectSysfsEntry(.named_pipe));
}

test "battery health falls back to charge-based hardware" {
    const health = batteryHealthPercent(null, null, 3_572_000, 3_193_000) orelse unreachable;
    try std.testing.expectApproxEqRel(89.3902575587906, health, 1e-12);
}

test "battery confidence marks synthesized metrics as derived" {
    try std.testing.expectEqual(models.Confidence.measured, batteryConfidence(true, false));
    try std.testing.expectEqual(models.Confidence.derived, batteryConfidence(true, true));
    try std.testing.expectEqual(models.Confidence.derived, batteryConfidence(false, false));
}
