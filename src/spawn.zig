const std = @import("std");
const Allocator = std.mem.Allocator;

/// Spawn a program detached from rill's session, process group, and
/// controlling terminal. This is the standard way window managers launch
/// interactive GUI programs and matches the behavior of kwm/dwl/etc.
pub fn spawnDetached(allocator: Allocator, argv: []const []const u8, environ_map: std.process.Environ.Map) void {
    if (argv.len == 0) {
        std.debug.print("spawnDetached: empty argv\n", .{});
        return;
    }

    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const argv_z = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch |err| {
        std.debug.print("spawnDetached: alloc argv failed: {}\n", .{err});
        return;
    };
    for (argv, 0..) |arg, i| {
        argv_z[i] = arena.dupeZ(u8, arg) catch |err| {
            std.debug.print("spawnDetached: dupe arg failed: {}\n", .{err});
            return;
        };
    }

    const env_block = environ_map.createPosixBlock(arena, .{}) catch |err| {
        std.debug.print("spawnDetached: create env block failed: {}\n", .{err});
        return;
    };

    const pid1 = std.os.linux.fork();
    switch (std.os.linux.errno(pid1)) {
        .SUCCESS => {},
        else => |err| {
            std.debug.print("spawnDetached: fork failed: {}\n", .{err});
            return;
        },
    }
    if (pid1 != 0) return; // parent returns immediately

    // First child: create a new session so the grandchild is fully detached
    // from rill's controlling terminal and process group.
    const sid = std.os.linux.setsid();
    switch (std.os.linux.errno(sid)) {
        .SUCCESS => {},
        else => std.os.linux.exit(1),
    }

    // Reset the signal mask so the spawned program inherits a clean mask
    // instead of any mask rill may have set.
    _ = std.os.linux.sigprocmask(
        std.posix.SIG.SETMASK,
        &std.os.linux.sigemptyset(),
        null,
    );

    // Second fork prevents the grandchild from ever becoming a session leader
    // and ensures it cannot reacquire a controlling terminal.
    const pid2 = std.os.linux.fork();
    switch (std.os.linux.errno(pid2)) {
        .SUCCESS => {},
        else => std.os.linux.exit(1),
    }
    if (pid2 != 0) std.os.linux.exit(0);

    // Grandchild: exec the target program.
    execveSearch(arena, argv[0], argv_z.ptr, env_block.slice.ptr, environ_map) catch |err| {
        std.debug.print("spawnDetached: exec {s} failed: {}\n", .{ argv[0], err });
    };
    std.os.linux.exit(1);
}

fn execveSearch(
    arena: Allocator,
    file: []const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    environ_map: std.process.Environ.Map,
) error{ExecFailed}!void {
    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        const file_z = arena.dupeZ(u8, file) catch return error.ExecFailed;
        const rc = std.os.linux.execve(file_z, argv, envp);
        if (std.os.linux.errno(rc) != .SUCCESS) return error.ExecFailed;
        unreachable;
    }

    const path = environ_map.get("PATH") orelse "/usr/local/bin:/bin:/usr/bin";
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full_path = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, file }, 0) catch continue;
        const rc = std.os.linux.execve(full_path, argv, envp);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => unreachable,
            .ACCES, .PERM, .NOENT, .NOTDIR => continue,
            else => return error.ExecFailed,
        }
    }
    return error.ExecFailed;
}
