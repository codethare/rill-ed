const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const keybinding = @import("keybinding.zig");
const types = @import("types.zig");

const Location = enum { XDG_CONFIG_HOME, HOME };

/// Load config from XDG_CONFIG_HOME, then HOME. Falls back to defaults (heap-allocated).
/// Propagates parse errors so the caller can decide whether to exit loudly.
/// Caller owns the returned pointer; free with std.zon.parse.free.
pub fn load(
    allocator: Allocator,
    io: Io,
    environ_map: std.process.Environ.Map,
) !*types.Config {
    if (find(allocator, io, .XDG_CONFIG_HOME, environ_map)) |config| {
        return config;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    if (find(allocator, io, .HOME, environ_map)) |config| {
        return config;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const default_cfg = allocator.create(types.Config) catch @panic("OOM");
    default_cfg.* = cloneConfig(allocator, .{}) catch @panic("OOM");
    return default_cfg;
}

fn cloneConfig(allocator: Allocator, cfg: types.Config) !types.Config {
    var cloned = cfg;
    cloned.keybindings = try cloneKeybindings(allocator, cfg.keybindings);
    cloned.pointer_bindings = try clonePointerBindings(allocator, cfg.pointer_bindings);
    cloned.spawn_at_startup = try cloneSpawnAtStartup(allocator, cfg.spawn_at_startup);
    cloned.window_rules = try cloneWindowRules(allocator, cfg.window_rules);
    return cloned;
}

fn cloneKeybindings(allocator: Allocator, keybindings: []const types.Keybinding) ![]const types.Keybinding {
    const source: []const types.Keybinding = if (keybindings.len == 0) &keybinding.default_keybindings else keybindings;
    const cloned = try allocator.dupe(types.Keybinding, source);
    for (cloned) |*kb| {
        kb.key = try allocator.dupeZ(u8, std.mem.sliceTo(kb.key, 0));
        switch (kb.action) {
            .spawn => |cmd| {
                const cloned_cmd = try allocator.dupe([]const u8, cmd);
                for (cloned_cmd) |*arg| {
                    arg.* = try allocator.dupe(u8, arg.*);
                }
                kb.action = .{ .spawn = cloned_cmd };
            },
            else => {},
        }
    }
    return cloned;
}

fn clonePointerBindings(allocator: Allocator, pointer_bindings: []const types.PointerBinding) ![]const types.PointerBinding {
    const source: []const types.PointerBinding = if (pointer_bindings.len == 0) &keybinding.default_pointer_bindings else pointer_bindings;
    return try allocator.dupe(types.PointerBinding, source);
}

fn cloneWindowRules(allocator: Allocator, rules: []const types.WindowRule) ![]const types.WindowRule {
    const cloned = try allocator.dupe(types.WindowRule, rules);
    for (cloned) |*rule| {
        if (rule.app_id) |a| rule.app_id = try allocator.dupeZ(u8, a);
        if (rule.title) |t| rule.title = try allocator.dupeZ(u8, t);
    }
    return cloned;
}

fn cloneSpawnAtStartup(allocator: Allocator, spawn_at_startup: []const []const []const u8) ![]const []const []const u8 {
    const cloned = try allocator.dupe([]const []const u8, spawn_at_startup);
    for (cloned) |*cmd| {
        const cloned_cmd = try allocator.dupe([]const u8, cmd.*);
        for (cloned_cmd) |*arg| {
            arg.* = try allocator.dupe(u8, arg.*);
        }
        cmd.* = cloned_cmd;
    }
    return cloned;
}

/// Reload config: free old config, parse new file, return the new pointer.
/// Returns null and keeps old config if no config file is found.
pub fn reload(
    allocator: Allocator,
    io: Io,
    environ_map: std.process.Environ.Map,
    old_config: *types.Config,
) ?*types.Config {
    const new_config = find(allocator, io, .XDG_CONFIG_HOME, environ_map) catch
        find(allocator, io, .HOME, environ_map) catch return null;

    std.zon.parse.free(allocator, old_config);
    const result = allocator.create(types.Config) catch {
        std.zon.parse.free(allocator, new_config);
        return null;
    };
    result.* = new_config.*;
    allocator.destroy(new_config);
    return result;
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
        io,
        path,
        allocator,
        .unlimited,
        .@"16",
        0,
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
