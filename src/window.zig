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
    if (event == .closed) {
        for (layout.pending_windows.items, 0..) |*pending, idx| {
            if (pending.river_window != river_window) continue;
            _ = layout.pending_windows.swapRemove(idx);
            river_window.destroy();
            return;
        }
    }

    if (event == .dimensions) {
        const ws = wm.currentWorkspace() orelse return;

        for (layout.pending_windows.items, 0..) |*pending, idx| {
            if (pending.river_window != river_window) continue;

            add(wm.allocator, pending.river_window, ws.output, wm.getConfig()) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            _ = layout.pending_windows.swapRemove(idx);

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
                        river_window.destroy();
                    },
                    .fullscreen_requested => {
                        window.is_fullscreen = true;
                    },
                    .exit_fullscreen_requested => {
                        window.is_fullscreen = false;
                    },
                    .title => |t| {
                        window.title = if (t.title) |title|
                            std.mem.sliceTo(title, 0)
                        else
                            null;
                        return;
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

fn add(
    allocator: Allocator,
    river_window: *river.WindowV1,
    output: *types.Output,
    config: *const types.Config,
) !void {
    const workspace = &output.workspace_list[output.focused_workspace_idx];
    const initial_rect = if (workspace.layout == .floating)
        layout.centerRectangle(output.non_exclusive, config)
    else
        layout.initialRectangle(output.non_exclusive, config);

    const window = types.Window{
        .river_window = river_window,
        .river_node = try river_window.getNode(),
        .proportion = config.default_window_width,
        .is_fullscreen = false,
        .is_floating = false,
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
