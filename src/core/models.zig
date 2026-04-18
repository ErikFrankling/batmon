const std = @import("std");

pub const Confidence = enum {
    measured,
    derived,
    estimated,
    unavailable,

    pub fn label(self: Confidence) []const u8 {
        return switch (self) {
            .measured => "measured",
            .derived => "derived",
            .estimated => "estimated",
            .unavailable => "unavailable",
        };
    }
};

pub const BatteryStatus = enum {
    charging,
    discharging,
    full,
    not_charging,
    unknown,

    pub fn fromSysfs(raw: []const u8) BatteryStatus {
        if (std.ascii.eqlIgnoreCase(raw, "Charging")) return .charging;
        if (std.ascii.eqlIgnoreCase(raw, "Discharging")) return .discharging;
        if (std.ascii.eqlIgnoreCase(raw, "Full")) return .full;
        if (std.ascii.eqlIgnoreCase(raw, "Not charging")) return .not_charging;
        if (std.ascii.eqlIgnoreCase(raw, "not_charging")) return .not_charging;
        return .unknown;
    }

    pub fn label(self: BatteryStatus) []const u8 {
        return switch (self) {
            .charging => "charging",
            .discharging => "discharging",
            .full => "full",
            .not_charging => "not_charging",
            .unknown => "unknown",
        };
    }
};

pub const BatterySample = struct {
    ts_wall: i64,
    ts_mono_ns: i64,
    percent: f64,
    ac_online: bool,
    status: BatteryStatus,
    power_w: ?f64,
    energy_now_wh: ?f64,
    energy_full_wh: ?f64,
    battery_count: u32,
    source: []const u8,
    confidence: Confidence,
};

pub const Event = struct {
    ts_start: i64,
    ts_end: i64,
    kind: []const u8,
    value: []const u8,
    details: []const u8,
};

pub const ProcessKey = struct {
    pid: i32,
    start_ticks: u64,
};

pub const ProcessCounters = struct {
    pid: i32,
    start_ticks: u64,
    ppid: i32,
    cpu_ticks: u64,
    read_bytes: u64,
    write_bytes: u64,
    rss_kib: u64,
    comm: []u8,
    exe: []u8,
    cgroup_path: []u8,

    pub fn deinit(self: *ProcessCounters, allocator: std.mem.Allocator) void {
        allocator.free(self.comm);
        allocator.free(self.exe);
        allocator.free(self.cgroup_path);
    }
};

pub const ProcessDelta = struct {
    pid: i32,
    start_ticks: u64,
    cpu_ticks_delta: u64,
    read_bytes_delta: u64,
    write_bytes_delta: u64,
    score: f64,
    process_label: []u8,
    bucket_key: []u8,
    bucket_label: []u8,

    pub fn deinit(self: *ProcessDelta, allocator: std.mem.Allocator) void {
        allocator.free(self.process_label);
        allocator.free(self.bucket_key);
        allocator.free(self.bucket_label);
    }
};

pub const BucketDelta = struct {
    key: []u8,
    label: []u8,
    cpu_ticks_delta: u64,
    read_bytes_delta: u64,
    write_bytes_delta: u64,
    score: f64,

    pub fn deinit(self: *BucketDelta, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.label);
    }
};

pub const StateSample = struct {
    section: []u8,
    key: []u8,
    value: []u8,
    availability: Confidence,

    pub fn deinit(self: *StateSample, allocator: std.mem.Allocator) void {
        allocator.free(self.section);
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const BatterySnapshot = struct {
    ts_wall: i64,
    percent: f64,
    ac_online: bool,
    status: BatteryStatus,
    power_w: ?f64,
    energy_now_wh: ?f64,
    energy_full_wh: ?f64,
    confidence: Confidence,
};

pub const GraphPoint = struct {
    ts_wall: i64,
    percent: f64,
    ac_online: bool,
    status: BatteryStatus,
    power_w: ?f64,
};

pub const ImpactRow = struct {
    label: []u8,
    aux: []u8,
    energy_wh: f64,
    battery_pct: f64,
    watts: f64,
    confidence: Confidence,

    pub fn deinit(self: *ImpactRow, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.aux);
    }
};

pub const StateRow = struct {
    section: []u8,
    key: []u8,
    value: []u8,
    availability: Confidence,

    pub fn deinit(self: *StateRow, allocator: std.mem.Allocator) void {
        allocator.free(self.section);
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

pub const TimeWindow = enum {
    hour1,
    hour6,
    day1,
    day7,

    pub fn seconds(self: TimeWindow) i64 {
        return switch (self) {
            .hour1 => 3600,
            .hour6 => 3600 * 6,
            .day1 => 3600 * 24,
            .day7 => 3600 * 24 * 7,
        };
    }

    pub fn label(self: TimeWindow) []const u8 {
        return switch (self) {
            .hour1 => "1h",
            .hour6 => "6h",
            .day1 => "24h",
            .day7 => "7d",
        };
    }
};

pub fn freeProcessCountersSlice(allocator: std.mem.Allocator, items: []ProcessCounters) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn freeProcessDeltaSlice(allocator: std.mem.Allocator, items: []ProcessDelta) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn freeBucketDeltaSlice(allocator: std.mem.Allocator, items: []BucketDelta) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn freeStateSampleSlice(allocator: std.mem.Allocator, items: []StateSample) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

test "battery status parsing" {
    try std.testing.expectEqual(BatteryStatus.charging, BatteryStatus.fromSysfs("Charging"));
    try std.testing.expectEqual(BatteryStatus.not_charging, BatteryStatus.fromSysfs("Not charging"));
    try std.testing.expectEqual(BatteryStatus.not_charging, BatteryStatus.fromSysfs("not_charging"));
    try std.testing.expectEqual(BatteryStatus.unknown, BatteryStatus.fromSysfs("mystery"));
}
