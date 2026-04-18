const std = @import("std");
const models = @import("models.zig");
const storage = @import("storage.zig");

const std_io = std.Options.debug_io;

const Tab = enum {
    impact,
    live,
    state,
    events,
};

const UiState = struct {
    tab: Tab = .impact,
    window: models.TimeWindow = .day1,
    window_offset_s: i64 = 0,
    process_mode: bool = false,
};

const Dimensions = struct {
    rows: usize,
    cols: usize,
};

pub fn run(allocator: std.mem.Allocator, db_path: []const u8) !void {
    var db = try storage.Db.open(allocator, db_path, true);
    defer db.close();

    var time_formatter = try TimeFormatter.init(allocator);
    defer time_formatter.deinit();

    var term = try Terminal.init();
    defer term.deinit();

    var state = UiState{};
    while (true) {
        try draw(allocator, &db, &term, &state, &time_formatter);
        if (try term.readKey(1000)) |key| {
            if (handleKey(&state, key)) break;
        }
    }
}

fn handleKey(state: *UiState, key: Key) bool {
    switch (key) {
        .char => |ch| switch (ch) {
            'q' => return true,
            '1' => state.tab = .impact,
            '2' => state.tab = .live,
            '3' => state.tab = .state,
            '4' => state.tab = .events,
            'a' => state.process_mode = !state.process_mode,
            '[' => state.window = prevWindow(state.window),
            ']' => state.window = nextWindow(state.window),
            'h' => state.window_offset_s += @divTrunc(state.window.seconds(), 4),
            'l' => state.window_offset_s = @max(state.window_offset_s - @divTrunc(state.window.seconds(), 4), 0),
            else => {},
        },
        .left => state.window_offset_s += @divTrunc(state.window.seconds(), 4),
        .right => state.window_offset_s = @max(state.window_offset_s - @divTrunc(state.window.seconds(), 4), 0),
        else => {},
    }
    return false;
}

fn prevWindow(window: models.TimeWindow) models.TimeWindow {
    return switch (window) {
        .hour1 => .hour1,
        .hour6 => .hour1,
        .day1 => .hour6,
        .day7 => .day1,
    };
}

fn nextWindow(window: models.TimeWindow) models.TimeWindow {
    return switch (window) {
        .hour1 => .hour6,
        .hour6 => .day1,
        .day1 => .day7,
        .day7 => .day7,
    };
}

fn draw(allocator: std.mem.Allocator, db: *storage.Db, term: *Terminal, ui: *const UiState, time_formatter: *const TimeFormatter) !void {
    const rows = term.size() catch Dimensions{ .rows = 40, .cols = 120 };
    const frame = try renderFrame(allocator, db, ui, time_formatter, rows);
    defer allocator.free(frame);
    try term.writeAll(frame);
}

fn renderFrame(allocator: std.mem.Allocator, db: *storage.Db, ui: *const UiState, time_formatter: *const TimeFormatter, rows: Dimensions) ![]u8 {
    const latest = try db.latestBattery();
    const now_ts = if (latest) |snapshot| snapshot.ts_wall else std.Io.Clock.real.now(std_io).toSeconds();
    const end_ts = now_ts - ui.window_offset_s;
    const start_ts = end_ts - ui.window.seconds();

    const graph = try db.queryGraph(allocator, start_ts, end_ts);
    defer allocator.free(graph);
    const events = try db.queryEvents(allocator, start_ts, end_ts);
    defer freeEvents(allocator, events);

    const graph_height = std.math.clamp(@divTrunc(rows.rows, 3), 8, 18);
    const rate_height: usize = 5;
    const event_lane_height: usize = 5;
    const pane_height = if (rows.rows > graph_height + rate_height + event_lane_height + 8) rows.rows - graph_height - rate_height - event_lane_height - 8 else 8;

    var aw = std.Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    const writer = &aw.writer;

    try writer.writeAll("\x1b[H\x1b[2J");
    try renderHeader(writer, latest, ui);
    try renderGraphSection(allocator, writer, graph, events, start_ts, end_ts, rows.cols - 2, graph_height);
    try renderRateGraph(allocator, writer, graph, start_ts, end_ts, rows.cols - 2, rate_height);
    try renderTabs(writer, ui);

    switch (ui.tab) {
        .impact => {
            const impact = try db.queryImpactRows(allocator, start_ts, end_ts, ui.process_mode, pane_height - 2);
            defer freeImpactRows(allocator, impact);
            try renderImpactPane(writer, impact, ui.process_mode, pane_height);
        },
        .live => {
            const live = try db.queryLiveRows(allocator, ui.process_mode, pane_height - 2);
            defer freeImpactRows(allocator, live);
            try renderLivePane(writer, live, ui.process_mode, pane_height);
        },
        .state => {
            const state_rows = try db.queryStateRows(allocator);
            defer freeStateRows(allocator, state_rows);
            try renderStatePane(writer, state_rows, pane_height);
        },
        .events => try renderEventsPane(writer, events, pane_height, time_formatter),
    }

    try writer.writeAll("\x1b[0m");
    return aw.toOwnedSlice();
}

fn renderHeader(writer: anytype, latest: ?models.BatterySnapshot, ui: *const UiState) !void {
    try writer.writeAll("\x1b[38;2;159;208;255m");
    try writer.print("batmon  \x1b[38;2;255;255;255mwindow={s}  offset={d}m  mode={s}\n", .{
        ui.window.label(),
        @divTrunc(ui.window_offset_s, 60),
        if (ui.process_mode) "processes" else "apps",
    });

    if (latest) |sample| {
        try writer.print("\x1b[38;2;255;209;102m{d:.1}%\x1b[0m  {s}  ac={s}  power=", .{
            sample.percent,
            sample.status.label(),
            if (sample.ac_online) "on" else "off",
        });
        try writeMaybeFloat(writer, sample.power_w, "W");
        try writer.writeAll("  energy=");
        try writeMaybeFloat(writer, sample.energy_now_wh, "Wh");
        try writer.writeAll("/");
        try writeMaybeFloat(writer, sample.energy_full_wh, "Wh");
        try writer.print("  confidence={s}\n\n", .{sample.confidence.label()});
    } else {
        try writer.writeAll("no battery data yet\n\n");
    }
}

fn renderGraphSection(allocator: std.mem.Allocator, writer: anytype, graph: []const models.GraphPoint, events: []const models.Event, start_ts: i64, end_ts: i64, width: usize, height: usize) !void {
    const usable_width = if (width > 12) width - 12 else width;
    const bins = try allocator.alloc(f64, usable_width);
    defer allocator.free(bins);
    const charging = try allocator.alloc(bool, usable_width);
    defer allocator.free(charging);
    const ac_online = try allocator.alloc(bool, usable_width);
    defer allocator.free(ac_online);
    const sleep = try allocator.alloc(bool, usable_width);
    defer allocator.free(sleep);
    const gaps = try allocator.alloc(bool, usable_width);
    defer allocator.free(gaps);
    const anomaly = try allocator.alloc(bool, usable_width);
    defer allocator.free(anomaly);

    for (bins) |*bin| bin.* = std.math.nan(f64);
    @memset(charging, false);
    @memset(ac_online, false);
    @memset(sleep, false);
    @memset(gaps, false);
    @memset(anomaly, false);

    for (graph) |point| {
        const idx = tsToColumn(point.ts_wall, start_ts, end_ts, usable_width);
        bins[idx] = point.percent;
        charging[idx] = point.status == .charging;
        ac_online[idx] = point.ac_online;
    }

    for (events) |event| {
        const from = tsToColumn(event.ts_start, start_ts, end_ts, usable_width);
        const to = tsToColumn(event.ts_end, start_ts, end_ts, usable_width);
        var idx = from;
        while (idx <= to and idx < usable_width) : (idx += 1) {
            if (std.mem.eql(u8, event.kind, "sleep")) sleep[idx] = true;
            if (std.mem.eql(u8, event.kind, "collector_gap")) gaps[idx] = true;
            if (std.mem.eql(u8, event.kind, "anomaly")) anomaly[idx] = true;
        }
    }

    var last_value: f64 = 0;
    for (bins, 0..) |value, idx| {
        if (std.math.isNan(value)) {
            bins[idx] = last_value;
        } else {
            last_value = value;
        }
    }

    try writer.writeAll("\x1b[38;2;175;215;255mBattery percentage\n");
    for (0..height) |row| {
        const top_pct = 100.0 - (@as(f64, @floatFromInt(row)) / @as(f64, @floatFromInt(height - 1))) * 100.0;
        try writer.print("\x1b[38;2;120;130;145m{d:>3.0}% │\x1b[0m", .{top_pct});
        for (0..usable_width) |idx| {
            const glyph = levelGlyph(bins[idx], height, row);
            const color = if (gaps[idx])
                "\x1b[38;2;255;99;132m"
            else if (sleep[idx])
                "\x1b[38;2;117;189;255m"
            else if (charging[idx])
                "\x1b[38;2;136;228;147m"
            else if (anomaly[idx])
                "\x1b[38;2;255;180;90m"
            else
                "\x1b[38;2;127;219;255m";
            try writer.writeAll(color);
            try writer.writeAll(glyph);
        }
        try writer.writeAll("\x1b[0m\n");
    }

    try renderEventLane(writer, "chg", usable_width, charging, "\x1b[48;2;29;84;41m");
    try renderEventLane(writer, "ac ", usable_width, ac_online, "\x1b[48;2;29;57;74m");
    try renderEventLane(writer, "slp", usable_width, sleep, "\x1b[48;2;31;55;89m");
    try renderEventLane(writer, "gap", usable_width, gaps, "\x1b[48;2;89;28;38m");
    try renderEventLane(writer, "ano", usable_width, anomaly, "\x1b[48;2;89;59;16m");
}

fn renderEventLane(writer: anytype, label: []const u8, width: usize, lane: []const bool, color: []const u8) !void {
    try writer.print("\x1b[38;2;120;130;145m{s:>3} │\x1b[0m", .{label});
    for (0..width) |idx| {
        if (lane[idx]) {
            try writer.writeAll(color);
            try writer.writeAll(" ");
        } else {
            try writer.writeAll("\x1b[48;2;18;21;27m ");
        }
    }
    try writer.writeAll("\x1b[0m\n");
}

fn renderRateGraph(allocator: std.mem.Allocator, writer: anytype, graph: []const models.GraphPoint, start_ts: i64, end_ts: i64, width: usize, height: usize) !void {
    const usable_width = if (width > 12) width - 12 else width;
    const bins = try allocator.alloc(f64, usable_width);
    defer allocator.free(bins);
    @memset(bins, 0);

    var max_rate: f64 = 1.0;
    if (graph.len >= 2) {
        for (graph[1..], graph[0 .. graph.len - 1]) |curr, prev| {
            if (curr.ts_wall <= prev.ts_wall) continue;
            const dt_h = @as(f64, @floatFromInt(curr.ts_wall - prev.ts_wall)) / 3600.0;
            if (dt_h <= 0) continue;
            const rate = @max((prev.percent - curr.percent) / dt_h, 0.0);
            const idx = tsToColumn(curr.ts_wall, start_ts, end_ts, usable_width);
            bins[idx] = rate;
            max_rate = @max(max_rate, rate);
        }
    }

    try writer.writeAll("\x1b[38;2;175;215;255mDischarge rate (%/hour)\n");
    for (0..height) |row| {
        const label_rate = max_rate - (@as(f64, @floatFromInt(row)) / @as(f64, @floatFromInt(height - 1))) * max_rate;
        try writer.print("\x1b[38;2;120;130;145m{d:>3.0} │\x1b[0m", .{label_rate});
        for (0..usable_width) |idx| {
            const glyph = rateGlyph(bins[idx], max_rate, height, row);
            try writer.writeAll("\x1b[38;2;255;209;102m");
            try writer.writeAll(glyph);
        }
        try writer.writeAll("\x1b[0m\n");
    }
}

fn renderTabs(writer: anytype, ui: *const UiState) !void {
    const tabs = [_]struct { name: []const u8, tab: Tab }{
        .{ .name = "1 Impact", .tab = .impact },
        .{ .name = "2 Live", .tab = .live },
        .{ .name = "3 State", .tab = .state },
        .{ .name = "4 Events", .tab = .events },
    };
    for (tabs) |item| {
        if (ui.tab == item.tab) {
            try writer.print("\x1b[48;2;38;52;74m\x1b[38;2;255;255;255m {s} \x1b[0m ", .{item.name});
        } else {
            try writer.print("\x1b[48;2;18;21;27m\x1b[38;2;120;130;145m {s} \x1b[0m ", .{item.name});
        }
    }
    try writer.writeAll("\n");
}

fn renderImpactPane(writer: anytype, rows: []const models.ImpactRow, process_mode: bool, height: usize) !void {
    try writer.print("Top estimated battery share ({s})\n", .{if (process_mode) "processes" else "apps"});
    try writer.writeAll("label                          bucket                %bat    Wh     W      conf\n");
    const max_rows = @min(rows.len, if (height > 2) height - 2 else 0);
    for (rows[0..max_rows]) |row| {
        try writer.print("{s:<30.30} {s:<20.20} {d:>6.2} {d:>6.2} {d:>6.2} {s}\n", .{
            row.label,
            row.aux,
            row.battery_pct,
            row.energy_wh,
            row.watts,
            row.confidence.label(),
        });
    }
}

fn renderLivePane(writer: anytype, rows: []const models.ImpactRow, process_mode: bool, height: usize) !void {
    try writer.print("Live estimated power ({s})\n", .{if (process_mode) "processes" else "apps"});
    try writer.writeAll("label                          bucket                watts   conf\n");
    const max_rows = @min(rows.len, if (height > 2) height - 2 else 0);
    for (rows[0..max_rows]) |row| {
        try writer.print("{s:<30.30} {s:<20.20} {d:>7.2} {s}\n", .{
            row.label,
            row.aux,
            row.watts,
            row.confidence.label(),
        });
    }
}

fn renderStatePane(writer: anytype, rows: []const models.StateRow, height: usize) !void {
    try writer.writeAll("Read-only power state\n");
    const max_rows = @min(rows.len, if (height > 1) height - 1 else 0);
    for (rows[0..max_rows]) |row| {
        try writer.print("[{s}] {s}: {s} ({s})\n", .{
            row.section,
            row.key,
            row.value,
            row.availability.label(),
        });
    }
}

fn renderEventsPane(writer: anytype, events: []const models.Event, height: usize, time_formatter: *const TimeFormatter) !void {
    try writer.writeAll("Recent timeline events\n");
    const max_rows = @min(events.len, if (height > 1) height - 1 else 0);
    const start = if (events.len > max_rows) events.len - max_rows else 0;
    for (events[start..]) |event| {
        try time_formatter.writeTimestamp(writer, event.ts_start);
        try writer.print(" {s:<14.14} {s} {s}\n", .{ event.kind, event.value, event.details });
    }
}

fn tsToColumn(ts: i64, start_ts: i64, end_ts: i64, width: usize) usize {
    if (width <= 1 or end_ts <= start_ts) return 0;
    if (ts <= start_ts) return 0;
    if (ts >= end_ts) return width - 1;
    const pos = @as(f64, @floatFromInt(ts - start_ts)) / @as(f64, @floatFromInt(end_ts - start_ts));
    const idx = @as(usize, @intFromFloat(pos * @as(f64, @floatFromInt(width - 1))));
    return @min(idx, width - 1);
}

fn levelGlyph(value: f64, height: usize, row: usize) []const u8 {
    const blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    const scaled = std.math.clamp(value, 0, 100) / 100.0 * @as(f64, @floatFromInt(height * 8));
    const row_base = @as(f64, @floatFromInt((height - row - 1) * 8));
    const diff = scaled - row_base;
    if (diff <= 0) return blocks[0];
    if (diff >= 8) return blocks[8];
    const idx = @as(usize, @intFromFloat(std.math.clamp(diff, 1, 7)));
    return blocks[idx];
}

fn rateGlyph(value: f64, max_rate: f64, height: usize, row: usize) []const u8 {
    const blocks = [_][]const u8{ " ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
    const scaled = if (max_rate > 0) (value / max_rate) * @as(f64, @floatFromInt(height * 8)) else 0;
    const row_base = @as(f64, @floatFromInt((height - row - 1) * 8));
    const diff = scaled - row_base;
    if (diff <= 0) return blocks[0];
    if (diff >= 8) return blocks[8];
    const idx = @as(usize, @intFromFloat(std.math.clamp(diff, 1, 7)));
    return blocks[idx];
}

fn freeEvents(allocator: std.mem.Allocator, events: []models.Event) void {
    for (events) |event| {
        allocator.free(@constCast(event.kind));
        allocator.free(@constCast(event.value));
        allocator.free(@constCast(event.details));
    }
    allocator.free(events);
}

fn freeImpactRows(allocator: std.mem.Allocator, rows: []models.ImpactRow) void {
    for (rows) |*row| row.deinit(allocator);
    allocator.free(rows);
}

fn freeStateRows(allocator: std.mem.Allocator, rows: []models.StateRow) void {
    for (rows) |*row| row.deinit(allocator);
    allocator.free(rows);
}

fn writeMaybeFloat(writer: anytype, value: ?f64, suffix: []const u8) !void {
    if (value) |number| {
        try writer.print("{d:.2}{s}", .{ number, suffix });
        return;
    }
    try writer.writeAll("n/a");
}

const Terminal = struct {
    old_termios: std.posix.termios,

    fn init() !Terminal {
        const old = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return error.TermiosReadFailed;

        var raw = old;
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch return error.TermiosWriteFailed;

        var term = Terminal{ .old_termios = old };
        try term.writeAll("\x1b[?1049h\x1b[?25l");
        return term;
    }

    fn deinit(self: *Terminal) void {
        const exit_seq = "\x1b[0m\x1b[?25h\x1b[?1049l";
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, self.old_termios) catch {};
        std.Io.File.writeStreamingAll(.stdout(), std_io, exit_seq) catch {};
    }

    fn writeAll(_: *const Terminal, bytes: []const u8) !void {
        std.Io.File.writeStreamingAll(.stdout(), std_io, bytes) catch return error.StdoutWriteFailed;
    }

    fn size(_: *const Terminal) !Dimensions {
        var ws: std.posix.winsize = .{
            .row = 0,
            .col = 0,
            .xpixel = 0,
            .ypixel = 0,
        };
        const rc = (try std_io.operate(.{ .device_io_control = .{
            .file = .stdout(),
            .code = std.posix.T.IOCGWINSZ,
            .arg = &ws,
        } })).device_io_control;
        if (rc < 0) return error.IoctlFailed;
        return Dimensions{
            .rows = @max(@as(usize, @intCast(ws.row)), 24),
            .cols = @max(@as(usize, @intCast(ws.col)), 80),
        };
    }

    fn readKey(_: *const Terminal, timeout_ms: i32) !?Key {
        var fds = [_]std.posix.pollfd{
            .{
                .fd = std.posix.STDIN_FILENO,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        const rc = try std.posix.poll(&fds, timeout_ms);
        if (rc == 0 or (fds[0].revents & std.posix.POLL.IN) == 0) return null;

        var buf: [3]u8 = undefined;
        const read_bytes = std.posix.read(std.posix.STDIN_FILENO, &buf) catch return null;
        if (read_bytes == 0) return null;
        if (read_bytes >= 3 and buf[0] == 0x1b and buf[1] == '[') {
            return switch (buf[2]) {
                'C' => .right,
                'D' => .left,
                else => .unknown,
            };
        }
        return .{ .char = buf[0] };
    }
};

const TimeFormatter = struct {
    allocator: std.mem.Allocator,
    tz: ?std.Tz,

    fn init(allocator: std.mem.Allocator) !TimeFormatter {
        return .{
            .allocator = allocator,
            .tz = try loadLocalTimezone(allocator),
        };
    }

    fn deinit(self: *TimeFormatter) void {
        if (self.tz) |*tz| tz.deinit();
    }

    fn writeTimestamp(self: *const TimeFormatter, writer: anytype, ts: i64) !void {
        const local_ts = self.localTimestamp(ts);
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(local_ts) };
        const day_seconds = epoch.getDaySeconds();
        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        });
    }

    fn localTimestamp(self: *const TimeFormatter, ts: i64) u64 {
        const offset = self.utcOffsetSeconds(ts);
        const adjusted = @as(i128, ts) + offset;
        return @intCast(@max(adjusted, 0));
    }

    fn utcOffsetSeconds(self: *const TimeFormatter, ts: i64) i64 {
        const tz = self.tz orelse return 0;
        if (tz.transitions.len == 0) return defaultTimetype(&tz).offset;

        var left: usize = 0;
        var right: usize = tz.transitions.len;
        while (left < right) {
            const mid = left + @divTrunc(right - left, 2);
            if (tz.transitions[mid].ts <= ts) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        if (left == 0) return defaultTimetype(&tz).offset;
        return tz.transitions[left - 1].timetype.offset;
    }

    fn defaultTimetype(tz: *const std.Tz) std.tz.Timetype {
        for (tz.timetypes) |tt| {
            if (!tt.isDst()) return tt;
        }
        return tz.timetypes[0];
    }
};

fn loadLocalTimezone(allocator: std.mem.Allocator) !?std.Tz {
    const bytes = std.Io.Dir.cwd().readFileAlloc(std_io, "/etc/localtime", allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    var reader: std.Io.Reader = .fixed(bytes);
    return std.Tz.parse(allocator, &reader) catch |err| switch (err) {
        error.BadHeader,
        error.BadVersion,
        error.Malformed,
        error.OverlargeFooter,
        error.EndOfStream,
        error.StreamTooLong,
        => null,
        else => return err,
    };
}

const Key = union(enum) {
    char: u8,
    left,
    right,
    unknown,
};

fn testDbPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

fn seedStateRows(allocator: std.mem.Allocator, db: *storage.Db, ts_wall: i64) !void {
    var rows = try allocator.alloc(models.StateSample, 2);
    errdefer allocator.free(rows);

    rows[0] = .{
        .section = try allocator.dupe(u8, "Configured state"),
        .key = try allocator.dupe(u8, "cpu_governor"),
        .value = try allocator.dupe(u8, "powersave"),
        .availability = .measured,
    };
    rows[1] = .{
        .section = try allocator.dupe(u8, "Configured state"),
        .key = try allocator.dupe(u8, "platform_profile"),
        .value = try allocator.dupe(u8, "balanced"),
        .availability = .derived,
    };
    defer models.freeStateSampleSlice(allocator, rows);

    try db.replaceState(ts_wall, rows);
}

fn seedTuiFixtureDb(allocator: std.mem.Allocator, db: *storage.Db) !void {
    try db.insertBatterySample(.{
        .ts_wall = 1_000,
        .ts_mono_ns = 1_000,
        .percent = 82.0,
        .ac_online = false,
        .status = .discharging,
        .power_w = 11.5,
        .energy_now_wh = 41.0,
        .energy_full_wh = 50.0,
        .battery_count = 1,
        .source = "sysfs",
        .confidence = .measured,
    });
    try db.insertBatterySample(.{
        .ts_wall = 1_600,
        .ts_mono_ns = 1_600,
        .percent = 79.5,
        .ac_online = false,
        .status = .discharging,
        .power_w = 12.0,
        .energy_now_wh = 39.5,
        .energy_full_wh = 50.0,
        .battery_count = 1,
        .source = "sysfs",
        .confidence = .measured,
    });
    try db.insertEvent(.{
        .ts_start = 1_200,
        .ts_end = 1_320,
        .kind = "sleep",
        .value = "suspend",
        .details = "detected from boottime/monotonic gap",
    });
    try db.insertBucketImpact(1_600, "firefox", "Firefox", 1.25, 2.5, 7.5, .estimated);
    try db.insertBucketLive(1_600, "firefox", "Firefox", 12.0, 10.0, .estimated);
    try seedStateRows(allocator, db, 1_600);
}

test "render frame emits visible content for empty database" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try testDbPath(allocator, &tmp.sub_path, "empty.db");
    defer allocator.free(db_path);

    var db = try storage.Db.open(allocator, db_path, false);
    defer db.close();

    var time_formatter = try TimeFormatter.init(allocator);
    defer time_formatter.deinit();

    const frame = try renderFrame(allocator, &db, &UiState{}, &time_formatter, .{ .rows = 30, .cols = 100 });
    defer allocator.free(frame);

    try std.testing.expect(frame.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, frame, "batmon") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Battery percentage") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "no battery data yet") != null);
}

test "render frame shows collector-produced impact data" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try testDbPath(allocator, &tmp.sub_path, "impact.db");
    defer allocator.free(db_path);

    {
        var write_db = try storage.Db.open(allocator, db_path, false);
        defer write_db.close();
        try seedTuiFixtureDb(allocator, &write_db);
    }

    var read_db = try storage.Db.open(allocator, db_path, true);
    defer read_db.close();

    var time_formatter = try TimeFormatter.init(allocator);
    defer time_formatter.deinit();

    const frame = try renderFrame(allocator, &read_db, &UiState{}, &time_formatter, .{ .rows = 32, .cols = 110 });
    defer allocator.free(frame);

    try std.testing.expect(std.mem.indexOf(u8, frame, "Top estimated battery share (apps)") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Firefox") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Battery percentage") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Discharge rate (%/hour)") != null);
}

test "render frame shows state and event panes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const db_path = try testDbPath(allocator, &tmp.sub_path, "panes.db");
    defer allocator.free(db_path);

    {
        var write_db = try storage.Db.open(allocator, db_path, false);
        defer write_db.close();
        try seedTuiFixtureDb(allocator, &write_db);
    }

    var read_db = try storage.Db.open(allocator, db_path, true);
    defer read_db.close();

    var time_formatter = try TimeFormatter.init(allocator);
    defer time_formatter.deinit();

    const state_frame = try renderFrame(allocator, &read_db, &UiState{ .tab = .state }, &time_formatter, .{ .rows = 32, .cols = 110 });
    defer allocator.free(state_frame);
    try std.testing.expect(std.mem.indexOf(u8, state_frame, "Read-only power state") != null);
    try std.testing.expect(std.mem.indexOf(u8, state_frame, "cpu_governor") != null);

    const events_frame = try renderFrame(allocator, &read_db, &UiState{ .tab = .events }, &time_formatter, .{ .rows = 32, .cols = 110 });
    defer allocator.free(events_frame);
    try std.testing.expect(std.mem.indexOf(u8, events_frame, "Recent timeline events") != null);
    try std.testing.expect(std.mem.indexOf(u8, events_frame, "sleep") != null);
}

test "render graph distinguishes ac-online from charging" {
    const allocator = std.testing.allocator;

    const graph = [_]models.GraphPoint{.{
        .ts_wall = 1_000,
        .percent = 100.0,
        .ac_online = true,
        .status = .not_charging,
        .power_w = null,
    }};
    const events = [_]models.Event{};

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try renderGraphSection(
        allocator,
        &aw.writer,
        &graph,
        &events,
        900,
        1_100,
        14,
        8,
    );

    const output = try aw.toOwnedSlice();
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[48;2;29;84;41m") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[38;2;136;228;147m") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ac ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[48;2;29;57;74m") != null);
}
