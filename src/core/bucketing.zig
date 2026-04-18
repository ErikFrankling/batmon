const std = @import("std");

const GenericWrappers = [_][]const u8{
    "bash",
    "bwrap",
    "dash",
    "dbus-daemon",
    "electron",
    "flatpak",
    "java",
    "node",
    "python",
    "python3",
    "sh",
    "systemd",
};

pub const Bucket = struct {
    key: []u8,
    label: []u8,
    process_label: []u8,

    pub fn deinit(self: *Bucket, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.label);
        allocator.free(self.process_label);
    }
};

pub fn derive(allocator: std.mem.Allocator, comm: []const u8, exe: []const u8, cgroup_path: []const u8) !Bucket {
    const process_label = try bestProcessLabel(allocator, comm, exe);

    if (meaningfulCgroupLabel(cgroup_path)) |candidate| {
        return .{
            .key = try allocator.dupe(u8, candidate),
            .label = try allocator.dupe(u8, prettify(candidate)),
            .process_label = process_label,
        };
    }

    if (!isGeneric(process_label)) {
        return .{
            .key = try allocator.dupe(u8, process_label),
            .label = try allocator.dupe(u8, prettify(process_label)),
            .process_label = process_label,
        };
    }

    const fallback = if (comm.len > 0) comm else "unknown";
    return .{
        .key = try allocator.dupe(u8, fallback),
        .label = try allocator.dupe(u8, prettify(fallback)),
        .process_label = process_label,
    };
}

fn bestProcessLabel(allocator: std.mem.Allocator, comm: []const u8, exe: []const u8) ![]u8 {
    const base = std.fs.path.basename(exe);
    const chosen = if (base.len > 0 and !isGeneric(base)) base else comm;
    return allocator.dupe(u8, if (chosen.len > 0) chosen else "unknown");
}

fn meaningfulCgroupLabel(cgroup_path: []const u8) ?[]const u8 {
    if (cgroup_path.len == 0) return null;

    var iter = std.mem.splitScalar(u8, cgroup_path, '/');
    var last: ?[]const u8 = null;
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.startsWith(u8, segment, "app-")) {
            last = segment;
        } else if (std.mem.endsWith(u8, segment, ".service") or std.mem.endsWith(u8, segment, ".scope")) {
            if (!std.mem.startsWith(u8, segment, "session-") and !std.mem.startsWith(u8, segment, "user@")) {
                last = segment;
            }
        }
    }
    return last;
}

fn prettify(raw: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = raw.len;

    if (std.mem.startsWith(u8, raw, "app-")) start = 4;
    if (std.mem.endsWith(u8, raw[start..], ".service")) end = raw.len - 8;
    if (std.mem.endsWith(u8, raw[start..], ".scope")) end = raw.len - 6;

    return raw[start..end];
}

fn isGeneric(label: []const u8) bool {
    for (GenericWrappers) |item| {
        if (std.ascii.eqlIgnoreCase(label, item)) return true;
    }
    return false;
}

test "prefer cgroup label when meaningful" {
    const allocator = std.testing.allocator;
    var bucket = try derive(allocator, "firefox", "/nix/store/firefox/bin/firefox", "/user.slice/user-1000.slice/app-firefox.scope");
    defer bucket.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, bucket.label, "firefox"));
}

test "fall back to executable when cgroup is generic" {
    const allocator = std.testing.allocator;
    var bucket = try derive(allocator, "node", "/nix/store/app/bin/discord", "/user.slice/user-1000.slice/session-2.scope");
    defer bucket.deinit(allocator);

    try std.testing.expect(std.mem.eql(u8, bucket.label, "discord"));
}

