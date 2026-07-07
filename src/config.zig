const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const types = @import("types.zig");

const Location = enum { XDG_CONFIG_HOME, HOME };

/// Load config from XDG_CONFIG_HOME, then HOME. Falls back to defaults (heap-allocated).
/// Caller owns the returned pointer; free with std.zon.parse.free.
pub fn load(
    allocator: Allocator,
    io: Io,
    environ_map: std.process.Environ.Map,
) *types.Config {
    if (find(allocator, io, .XDG_CONFIG_HOME, environ_map)) |config| return config else |err|
        std.debug.print("Failed to load config from $XDG_CONFIG_HOME: {}\n", .{err});
    if (find(allocator, io, .HOME, environ_map)) |config| return config else |err|
        std.debug.print("Failed to load config from $HOME: {}\n", .{err});

    const default_cfg = allocator.create(types.Config) catch @panic("OOM");
    default_cfg.* = .{};
    return default_cfg;
}

/// Reload config: free old fields, parse new file, swap in.
/// Returns null and keeps old config if no config file is found.
pub fn reload(
    allocator: Allocator,
    io: Io,
    environ_map: std.process.Environ.Map,
    old_config: *types.Config,
) ?*types.Config {
    if (find(allocator, io, .XDG_CONFIG_HOME, environ_map)) |new_config| {
        std.zon.parse.free(allocator, old_config);
        old_config.* = new_config.*;
        allocator.destroy(new_config);
        return old_config;
    } else |_| {}
    if (find(allocator, io, .HOME, environ_map)) |new_config| {
        std.zon.parse.free(allocator, old_config);
        old_config.* = new_config.*;
        allocator.destroy(new_config);
        return old_config;
    } else |_| {}
    return null;
}

fn find(
    allocator: Allocator,
    io: Io,
    location: Location,
    environ_map: std.process.Environ.Map,
) !*types.Config {
    const env = environ_map.get(@tagName(location)) orelse return error.FileNotFound;

    const path = switch (location) {
        .XDG_CONFIG_HOME => try Io.Dir.path.join(allocator, &.{ env, "rill", "config.zon" }),
        .HOME => try Io.Dir.path.join(allocator, &.{ env, ".config", "rill", "config.zon" }),
    };
    defer allocator.free(path);

    const content = try Io.Dir.cwd().readFileAllocOptions(
        io, path, allocator, .unlimited, .@"16", 0,
    );
    defer allocator.free(content);

    return try std.zon.parse.fromSliceAlloc(*types.Config, allocator, content, null, .{});
}

test "default Config struct has all expected fields" {
    const cfg = types.Config{};
    try std.testing.expect(cfg.vertical_gap >= 0);
    try std.testing.expect(cfg.horizontal_gap >= 0);
    try std.testing.expect(cfg.default_window_width > 0);
    try std.testing.expect(cfg.border.width > 0);
}
