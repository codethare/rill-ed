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
    const output_idx = wm.focused_output_idx orelse return;

    if (event == .dimensions) {
        for (layout.pending_windows.items, 0..) |window, idx| {
            if (window != river_window) continue;

            const output = &wm.output_list.items[output_idx];
            add(wm.allocator, window, output, wm.getConfig()) catch |err| {
                std.debug.print("Failed to add window: {}\n", .{err});
                return;
            };
            _ = layout.pending_windows.swapRemove(idx);

            layout.update(wm.output_list, wm.getConfig());
            wm.status = .layout;
            wm.river_window_manager.?.manageDirty();
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
    config: types.Config,
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
        .is_closing = false,
        .floating = initial_rect,
        .current = initial_rect,
        .start = null,
        .finish = null,
    };

    var window_idx: usize = 0;
    if (workspace.focused_window_idx) |idx| window_idx = idx + 1;
    try workspace.window_list.insert(allocator, window_idx, window);
    workspace.focused_window_idx = window_idx;
}
