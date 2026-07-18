const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const river = wayland.client.river;

const layout = @import("layout.zig");
const types = @import("types.zig");

pub fn windowListener(
    river_window: *river.WindowV1,
    event: river.WindowV1.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .title => |e| setPendingString(wm, river_window, .title, e.title),
        .app_id => |e| setPendingString(wm, river_window, .app_id, e.app_id),
        else => {},
    }

    if (event == .closed) {
        for (wm.pending_windows.items, 0..) |*pending, idx| {
            if (pending.river_window != river_window) continue;
            freePendingStrings(wm.allocator, pending);
            _ = wm.pending_windows.swapRemove(idx);
            river_window.destroy();
            return;
        }
    }

    if (event == .dimensions) {
        const ws = wm.currentWorkspace() orelse return;

        for (wm.pending_windows.items, 0..) |*pending, idx| {
            if (pending.river_window != river_window) continue;

            add(wm.allocator, pending.*, ws.output, wm.getConfig()) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            freePendingStrings(wm.allocator, pending);
            _ = wm.pending_windows.swapRemove(idx);

            layout.update(wm.output_list, wm.getConfig());
            wm.status = .layout;
            if (wm.river_window_manager) |wmgr| wmgr.manageDirty();
            return;
        }
    }

    for (wm.output_list.items) |*output| {
        for (&output.workspace_list) |*workspace| {
            const window_idx = workspace.focused_window_idx orelse continue;

            for (workspace.window_list.items, 0..) |*window, idx| {
                if (window.river_window != river_window) continue;

                switch (event) {
                    .closed => {
                        if (workspace.window_list.items.len == 1) {
                            workspace.focused_window_idx = null;
                        } else if (idx <= window_idx and window_idx != 0) {
                            workspace.focused_window_idx = window_idx - 1;
                        }

                        _ = workspace.window_list.orderedRemove(idx);
                        if (wm.last_focused_window == river_window) {
                            wm.last_focused_window = null;
                        }
                        if (wm.lock_focus == river_window) {
                            wm.lock_focus = null;
                        }
                        river_window.destroy();
                    },
                    .fullscreen_requested => {
                        window.is_fullscreen = true;
                    },
                    .exit_fullscreen_requested => {
                        window.is_fullscreen = false;
                    },

                    else => return,
                }

                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;
                return;
            }
        }
    }
}

fn setPendingString(
    wm: *types.WindowManager,
    river_window: *river.WindowV1,
    comptime field: enum { title, app_id },
    value: ?[*:0]const u8,
) void {
    for (wm.pending_windows.items) |*pending| {
        if (pending.river_window != river_window) continue;
        const field_ptr = &@field(pending, @tagName(field));
        if (field_ptr.*) |old| wm.allocator.free(old);
        field_ptr.* = if (value) |v|
            wm.allocator.dupeZ(u8, std.mem.span(v)) catch null
        else
            null;
        return;
    }
}

fn freePendingStrings(allocator: Allocator, pending: *const types.PendingWindow) void {
    if (pending.title) |t| allocator.free(t);
    if (pending.app_id) |a| allocator.free(a);
}

fn add(
    allocator: Allocator,
    pending: types.PendingWindow,
    output: *types.Output,
    config: *const types.Config,
) !void {
    const river_window = pending.river_window;
    const workspace = &output.workspace_list[output.focused_workspace_idx];

    var is_floating = false;
    for (config.window_rules) |rule| {
        if (rule.matches(pending.app_id, pending.title) and rule.floating) {
            is_floating = true;
            break;
        }
    }

    const initial_rect = if (workspace.layout == .floating or is_floating)
        layout.centerRectangle(output.non_exclusive, config)
    else
        layout.initialRectangle(output.non_exclusive, config);

    const window = types.Window{
        .river_window = river_window,
        .river_node = try river_window.getNode(),
        .proportion = config.default_window_width,
        .is_fullscreen = false,
        .is_floating = is_floating,
        .is_closing = false,
        .floating = initial_rect,
        .current = initial_rect,
        .start = null,
        .finish = null,
        .sent_current = null,
        .sent_clip = null,
        .sent_visible = null,
    };

    var window_idx: usize = 0;
    if (workspace.focused_window_idx) |idx| window_idx = idx + 1;
    try workspace.window_list.insert(allocator, window_idx, window);
    workspace.focused_window_idx = window_idx;
}
