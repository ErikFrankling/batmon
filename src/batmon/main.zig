const std = @import("std");
const core = @import("core");

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.smp_allocator;

    var db_path = try defaultDatabasePath(allocator, init.environ);
    defer allocator.free(db_path);

    var args = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--database-path")) {
            if (args.next()) |value| {
                allocator.free(db_path);
                db_path = try allocator.dupe(u8, value);
            } else {
                return error.MissingDatabasePath;
            }
        }
    }

    try core.tui.run(allocator, db_path);
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
