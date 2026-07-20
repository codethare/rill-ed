const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wayland = @import("wayland");
const river = wayland.client.river;

const animation = @import("animation.zig");
const config = @import("config.zig");
const keybinding = @import("keybinding.zig");
const layout = @import("layout.zig");
const output = @import("output.zig");
const overview = @import("overview.zig");
const seat = @import("seat.zig");
const spawn = @import("spawn.zig");
const types = @import("types.zig");
const window = @import("window.zig");

pub fn main(init: std.process.Init) !void {
    // Auto-reap children without breaking waitpid() in spawned programs.
    // SA_NOCLDWAIT alone prevents zombies while preserving waitpid() semantics
    // for children that use fork()+waitpid() internally (wmenu, shells, etc.).
    // Using SIG_IGN would be inherited by children and break their waitpid().
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.NOCLDWAIT,
    };
    std.posix.sigaction(std.posix.SIG.CHLD, &sa, null);

    // Die when our parent (typically river -c rill) dies, so we don't
    // get reparented to init and outlive the session if river crashes
    // or is killed.
    _ = std.os.linux.prctl(
        @intFromEnum(std.os.linux.PR.SET_PDEATHSIG),
        @intCast(@intFromEnum(std.posix.SIG.TERM)),
        0,
        0,
        0,
    );

    const display = try wayland.client.wl.Display.connect(null);
    defer display.disconnect();

    const cfg = config.load(init.gpa, init.io, init.environ_map.*) catch |err| {
        std.debug.print("Failed to load config: {}\n", .{err});
        return error.ConfigLoadFailed;
    };

    var wm = types.WindowManager{
        .allocator = init.gpa,
        .io = init.io,
        .environ_map = init.environ_map.*,
        .registry = try display.getRegistry(),
        .river_window_manager = null,
        .river_xkb_bindings = null,
        .river_layer_shell = null,
        .river_seat = null,
        .output_list = .empty,
        .focused_output_idx = null,
        .previous_workspace = null,
        .config = cfg,
        .xkb_binding_list = .empty,
        .pointer_binding_list = .empty,
        .detached_outputs = std.StringHashMap(types.DetachedOutput).init(init.gpa),
        .status = .none,
    };
    defer wm.deinit();

    wm.registry.setListener(*types.WindowManager, registryListener, &wm);
    _ = display.roundtrip();

    const window_manager = wm.river_window_manager orelse {
        std.debug.print("Failed to find window manager\n", .{});
        return;
    };
    window_manager.setListener(*types.WindowManager, windowManagerListener, &wm);

    for (wm.getConfig().spawn_at_startup) |command| {
        spawn.spawnDetached(wm.allocator, command, wm.environ_map);
    }

    while (true) {
        // Drain any already-queued events without blocking.
        var status = display.dispatchPending();
        if (status != .SUCCESS) {
            std.debug.print("Window manager stopped with status (pending): {}\n", .{status});
            break;
        }

        // prepareRead returns true when the queue is empty and we
        // are clear to poll. If false, events accumulated between
        // dispatchPending and prepareRead — loop back to drain them.
        if (display.prepareRead()) {
            // Flush outgoing requests before polling so the compositor
            // can respond to them without delay.
            _ = display.flush();

            var fds = [_]std.posix.pollfd{
                .{ .fd = display.getFd(), .events = std.posix.POLL.IN, .revents = 0 },
            };
            // 5-second timeout so we don't block forever when the
            // compositor is unresponsive (e.g. after hibernate/resume).
            const poll_ret = std.posix.poll(&fds, 5000) catch |err| {
                display.cancelRead();
                std.debug.print("Window manager poll error: {}\n", .{err});
                continue;
            };
            if (poll_ret == 0) {
                // Timeout — compositor hasn't sent anything.
                display.cancelRead();
                continue;
            }
            // Check for hangup / error on the socket fd.
            if (fds[0].revents & std.posix.POLL.HUP != 0 or
                fds[0].revents & std.posix.POLL.ERR != 0)
            {
                display.cancelRead();
                std.debug.print("Window manager stopped: compositor connection closed\n", .{});
                break;
            }
            // Events ready — readEvents takes over from prepareRead.
            status = display.readEvents();
            if (status != .SUCCESS) {
                std.debug.print("Window manager stopped (read): {}\n", .{status});
                break;
            }
        }

        status = display.dispatchPending();
        if (status != .SUCCESS) {
            std.debug.print("Window manager stopped with status (dispatch): {}\n", .{status});
            break;
        }

        if (wm.should_exit_loop) break;
        if (wm.status == .animation) {
            if (wm.river_window_manager) |wmgr| wmgr.manageDirty();
        }
    }
}

fn registryListener(
    registry: *wayland.client.wl.Registry,
    event: wayland.client.wl.Registry.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .global => |global| {
            const interface_name = std.mem.span(global.interface);
            if (std.mem.eql(u8, interface_name, "river_window_manager_v1")) {
                wm.river_window_manager =
                    registry.bind(global.name, river.WindowManagerV1, 4) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_xkb_bindings_v1")) {
                wm.river_xkb_bindings =
                    registry.bind(global.name, river.XkbBindingsV1, 1) catch null;
            } else if (std.mem.eql(u8, interface_name, "river_layer_shell_v1")) {
                wm.river_layer_shell =
                    registry.bind(global.name, river.LayerShellV1, 1) catch null;
            }
        },
        .global_remove => {},
    }
}

fn windowManagerListener(
    window_manager: *river.WindowManagerV1,
    event: river.WindowManagerV1.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .output => |output_event| output.add(wm.allocator, output_event.id, wm) catch |err|
            std.debug.print("Failed to add output: {}\n", .{err}),
        .seat => |seat_event| {
            wm.river_seat = seat_event.id;
            seat_event.id.setListener(*types.WindowManager, seat.seatListener, wm);

            if (wm.getConfig().cursor) |cursor| {
                seat_event.id.setXcursorTheme(cursor.theme, cursor.size);
            }
            wm.status = .setup_bindings;

            const layer_shell = wm.river_layer_shell orelse {
                std.debug.print("Failed to find layer shell\n", .{});
                return;
            };
            const layer_shell_seat = layer_shell.getSeat(seat_event.id) catch {
                std.debug.print("Failed to get layer shell seat\n", .{});
                return;
            };
            layer_shell_seat.setListener(*types.WindowManager, seat.layerShellSeatListener, wm);
        },
        .window => |window_event| {
            wm.pending_windows.append(wm.allocator, .{ .river_window = window_event.id }) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            window_event.id.setListener(*types.WindowManager, window.windowListener, wm);
            wm.status = .layout;
        },
        .manage_start => {
            manage(wm.allocator, wm.io, wm);
            window_manager.manageFinish();
        },
        .render_start => window_manager.renderFinish(),
        .finished => {
            window_manager.destroy();
            wm.river_window_manager = null;
            wm.should_exit_loop = true;
        },
        .session_locked => {
            wm.session_locked = true;
            // Save the focused window before lock so we can restore it after
            // waylock, mirroring KWM's save/restore pattern for the lock mode.
            wm.lock_focus = if (wm.currentFocus()) |focus| focus.window.river_window else null;
        },
        .session_unlocked => {
            wm.session_locked = false;
            // Restore focus to the window that was focused before lock, wherever
            // it currently lives (it may have migrated across outputs during lock).
            if (wm.lock_focus) |locked_window| {
                outer: for (wm.output_list.items, 0..) |*out, output_idx| {
                    for (&out.workspace_list, 0..) |*workspace, workspace_idx| {
                        for (workspace.window_list.items, 0..) |*win, window_idx| {
                            if (win.river_window == locked_window) {
                                wm.focused_output_idx = output_idx;
                                out.focused_workspace_idx = workspace_idx;
                                workspace.focused_window_idx = window_idx;
                                break :outer;
                            }
                        }
                    }
                }
            }
            wm.lock_focus = null;
            wm.layer_shell_focus = .none;
            // The lock surface held keyboard focus, so the cached
            // last_focused_window is stale; invalidate it so
            // applyFocusAndBorders re-issues focusWindow on unlock.
            wm.last_focused_window = null;
            wm.needs_refocus = true;
            wm.status = .layout;
            if (wm.river_window_manager) |wmgr| wmgr.manageDirty();
        },
        .unavailable => {
            std.debug.print("Window manager unavailable (another WM is active), exiting\n", .{});
            wm.status = .exit;
            wm.should_exit_loop = true;
        },
    }
}

fn manage(allocator: Allocator, io: Io, wm: *types.WindowManager) void {
    if (wm.needs_setup_bindings) {
        wm.status = .setup_bindings;
        wm.needs_setup_bindings = false;
    }

    if (wm.focused_output_idx == null) return;
    const river_seat = wm.river_seat orelse {
        std.debug.print("Failed to find seat\n", .{});
        return;
    };

    switch (wm.status) {
        .layout => {
            layout.apply(
                allocator,
                wm,
                river_seat,
            );
            if (wm.needs_refocus) {
                // focusWindow may have been ignored during exclusive focus;
                // stay in .layout so the next manage sequence retries focus.
                wm.needs_refocus = false;
                if (wm.river_window_manager) |wm_proto| wm_proto.manageDirty();
            } else {
                wm.status = .{
                    .animation = Io.Clock.awake.now(io).toMilliseconds(),
                };
            }
        },
        .animation => |start_time| {
            const focused_output_idx = wm.focused_output_idx orelse {
                wm.status = .none;
                return;
            };
            wm.status = animation.apply(
                wm.output_list,
                focused_output_idx,
                wm.getConfig(),
                start_time,
                Io.Clock.awake.now(io).toMilliseconds(),
            );
            // Refresh borders and focus every animation frame so focus changes
            // that arrive while an animation is active are visible immediately.
            layout.applyFocusAndBorders(wm, river_seat);
        },
        .overview => {
            overview.applyBorders(wm, river_seat);
            wm.status = .{
                .animation = Io.Clock.awake.now(io).toMilliseconds(),
            };
        },
        .pointer_action => {
            const focused_output_idx = wm.focused_output_idx orelse return;
            river_seat.opStartPointer();
            seat.pointerAction(&wm.output_list, focused_output_idx, wm.getConfig());
        },
        .setup_bindings => {
            var bind_ok = true;
            keybinding.setupKeybindings(allocator, wm) catch |err| {
                std.debug.print("Failed to setup keybindings: {}\n", .{err});
                bind_ok = false;
            };
            seat.setupPointerBindings(allocator, wm) catch |err| {
                std.debug.print("Failed to setup pointer bindings: {}\n", .{err});
                bind_ok = false;
            };
            if (!bind_ok) return;

            wm.status = .layout;
            if (wm.river_window_manager) |wmgr| wmgr.manageDirty();
        },
        .exit => {
            // Cleanup handled by defer wm.deinit() in main() — don't call it here
            if (wm.river_window_manager) |wmgr| wmgr.exitSession();
        },
        .none => river_seat.opEnd(),
    }
}

test {
    std.testing.refAllDecls(@This());
}
