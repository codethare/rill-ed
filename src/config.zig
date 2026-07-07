const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const types = @import("types.zig");

const Location = enum { XDG_CONFIG_HOME, HOME };

pub fn load(
    allocator: Allocator,
    io: Io,
    environ_map: std.process.Environ.Map,
) ?*types.Config {
    if(find(allocator, io, .XDG_CONFIG_HOME, environ_map)) |config| {
        return config;
    } else |err|
        std.debug.print("Failed to load config from $XDG_CONFIG_HOME: {}\n", .{err});

    if(find(allocator, io, .HOME, environ_map)) |config| {
        return config;
    } else |err|
        std.debug.print("Failed to load config from $HOME: {}\n", .{err});

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
        .XDG_CONFIG_HOME => try Io.Dir.path.join(allocator, &.{
            env,
            "rill",
            "config.zon",
        }),
        .HOME => try Io.Dir.path.join(allocator, &.{
            env,
            ".config",
            "rill",
            "config.zon",
        }),
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

    const config = try std.zon.parse.fromSliceAlloc(
        *types.Config,
        allocator,
        content,
        null,
        .{},
    );

    return config;
}

test "default Config struct has all expected fields" {
    // Verify the Config struct can be instantiated with all defaults
    const cfg = types.Config{};

    // Check key fields have reasonable defaults
    try std.testing.expect(cfg.vertical_gap >= 0);
    try std.testing.expect(cfg.horizontal_gap >= 0);
    try std.testing.expect(cfg.default_window_width > 0);
    try std.testing.expect(cfg.border.width > 0);

    // ponytail: ZON-file roundtrip test skipped — @import("default_config")
    // crashes the Zig compiler (config.zon isn't valid Zig source).
    // Revisit when ZON embedding is supported in the build system.
}
