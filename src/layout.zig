const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const common = @import("layout/common.zig");
pub const initialRectangle = common.initialRectangle;
pub const centerRectangle = common.centerRectangle;
const scroller = @import("layout/scroller.zig");
const floating = @import("layout/floating.zig");

pub const PendingWindow = struct {
    river_window: *river.WindowV1,
    initialized: bool = false,
};

pub var pending_windows: std.ArrayList(PendingWindow) = .empty;

pub fn update(output_list: std.ArrayList(types.Output), config: *const types.Config) void {
    for (output_list.items) |*output| {
        for (&output.workspace_list, 0..) |*workspace, workspace_idx| {
            const workspace_offset = @as(i32, @intCast(workspace_idx)) -
                @as(i32, @intCast(output.focused_workspace_idx));
            const y_offset = workspace_offset * output.rectangle.height;

            switch (workspace.layout) {
                .floating => floating.apply(workspace, output, y_offset),
                .scroller => scroller.apply(workspace, output, config, y_offset),
            }
        }
    }
}

pub fn apply(
    allocator: Allocator,
    wm: *types.WindowManager,
    river_seat: *river.SeatV1,
) void {
    const config = wm.getConfig();

    for (pending_windows.items) |*pending| {
        if (pending.initialized) continue;
        const window = pending.river_window;
        if (config.no_csd) window.useSsd();
        window.setTiled(common.edges);
        window.proposeDimensions(0, 0);
        pending.initialized = true;
    }

    const output_list = &wm.output_list;
    const focused_output_idx = &wm.focused_output_idx;

    const non_removed_count = countNonRemoved(output_list);
    const migration_target_idx: ?usize = if (non_removed_count > 0) firstNonRemoved(output_list) else null;

    var output_idx = output_list.items.len;
    while (output_idx > 0) {
        output_idx -= 1;
        const output = &output_list.items[output_idx];

        if (output.is_removed) {
            if (migration_target_idx) |target_idx| {
                for (&output.workspace_list, 0..) |*src_ws, ws_idx| {
                    const target_ws = &output_list.items[target_idx].workspace_list[ws_idx];
                    const offset = target_ws.window_list.items.len;
                    for (src_ws.window_list.items) |window| {
                        if (window.is_fullscreen) window.river_window.exitFullscreen();
                        target_ws.window_list.append(allocator, window) catch {
                            window.river_window.destroy();
                        };
                    }
                    if (src_ws.focused_window_idx) |fwi| {
                        if (target_ws.focused_window_idx == null) {
                            target_ws.focused_window_idx = offset + fwi;
                        }
                    }
                    src_ws.window_list.deinit(allocator);
                }
            } else {
                if (wm.detached_workspaces) |*detached| {
                    // Avoid leaking the previously detached workspaces by
                    // freeing their backing memory before overwriting.
                    for (detached) |*workspace| {
                        workspace.window_list.deinit(allocator);
                    }
                }
                wm.detached_workspaces = output.workspace_list;
            }

            if (focused_output_idx.*) |foi| {
                if (foi == output_idx) {
                    if (output_list.items.len > 1) {
                        focused_output_idx.* = @min(output_idx, output_list.items.len - 2);
                    } else {
                        focused_output_idx.* = null;
                    }
                } else if (foi > output_idx) {
                    focused_output_idx.* = foi - 1;
                }
            }

            _ = output_list.swapRemove(output_idx);
            continue;
        }

        for (output.workspace_list) |workspace| {
            for (workspace.window_list.items) |*window| {
                const was_fullscreen = window.start != null and
                    window.start.?.x == output.rectangle.x and
                    window.start.?.y == output.rectangle.y and
                    window.start.?.width == output.rectangle.width and
                    window.start.?.height == output.rectangle.height;
                if (was_fullscreen) window.river_window.exitFullscreen();

                if (window.is_closing) window.river_window.close();
            }
        }
    }

    applyFocusAndBorders(wm, river_seat);
}

/// Set border colors and keyboard focus to match the current focused
/// window/output. Safe to call every frame: redundant border and focus requests
/// are skipped so IME clients are not disrupted.
pub fn applyFocusAndBorders(
    wm: *types.WindowManager,
    river_seat: *river.SeatV1,
) void {
    const config = wm.getConfig();
    const unfocused_color = config.border.unfocused_color.toRiverColor();
    const focused_color = config.border.focused_color.toRiverColor();

    const foi = wm.focused_output_idx orelse return;

    for (wm.output_list.items, 0..) |*output, output_idx| {
        if (output.is_removed) continue;

        for (output.workspace_list, 0..) |workspace, workspace_idx| {
            for (workspace.window_list.items, 0..) |*window, window_idx| {
                const is_focused = output_idx == foi and
                    workspace_idx == output.focused_workspace_idx and
                    window_idx == workspace.focused_window_idx;

                if (window.sent_border_focused == null or
                    window.sent_border_focused.? != is_focused)
                {
                    const color = if (is_focused) focused_color else unfocused_color;
                    window.river_window.setBorders(
                        common.edges,
                        config.border.width,
                        color.r,
                        color.g,
                        color.b,
                        color.a,
                    );
                    window.sent_border_focused = is_focused;
                }

                if (!is_focused) continue;
                window.river_node.placeTop();
            }
        }

        if (output_idx != foi) continue;
        if (output.river_layer_shell_output) |layer_shell_output| {
            layer_shell_output.setDefault();
        }
    }

    // Only send focus commands when the target actually changes. Unconditional
    // clear_focus/focus_window cycles deactivate input method clients such as
    // fcitx5 and kwim on every layout pass.
    if (wm.layer_shell_focus == .exclusive) {
        if (wm.last_focused_window != null) {
            river_seat.clearFocus();
            wm.last_focused_window = null;
        }
        return;
    }

    const desired_focus: ?*river.WindowV1 = blk: {
        const output = &wm.output_list.items[foi];
        const workspace = &output.workspace_list[output.focused_workspace_idx];
        const fwi = workspace.focused_window_idx orelse break :blk null;
        break :blk workspace.window_list.items[fwi].river_window;
    };

    if (desired_focus != wm.last_focused_window) {
        if (desired_focus) |window| {
            river_seat.focusWindow(window);
        } else if (wm.layer_shell_focus != .non_exclusive) {
            river_seat.clearFocus();
        }
        wm.last_focused_window = desired_focus;
    }
}

fn countNonRemoved(output_list: *std.ArrayList(types.Output)) usize {
    var count: usize = 0;
    for (output_list.items) |output| {
        if (!output.is_removed) count += 1;
    }
    return count;
}

fn firstNonRemoved(output_list: *std.ArrayList(types.Output)) usize {
    for (output_list.items, 0..) |output, idx| {
        if (!output.is_removed) return idx;
    }
    unreachable;
}

test "countNonRemoved" {
    var list: std.ArrayList(types.Output) = .empty;
    defer list.deinit(std.testing.allocator);

    try list.append(std.testing.allocator, .{
        .river_output = undefined,
        .river_layer_shell_output = null,
        .workspace_list = [_]types.Workspace{.{}} ** 10,
        .focused_workspace_idx = 0,
        .rectangle = .{ .width = 0, .height = 0, .x = 0, .y = 0 },
        .non_exclusive = .{ .width = 0, .height = 0, .x = 0, .y = 0 },
        .is_removed = false,
    });
    try list.append(std.testing.allocator, .{
        .river_output = undefined,
        .river_layer_shell_output = null,
        .workspace_list = [_]types.Workspace{.{}} ** 10,
        .focused_workspace_idx = 0,
        .rectangle = .{ .width = 0, .height = 0, .x = 0, .y = 0 },
        .non_exclusive = .{ .width = 0, .height = 0, .x = 0, .y = 0 },
        .is_removed = false,
    });

    try std.testing.expectEqual(@as(usize, 2), countNonRemoved(&list));

    list.items[0].is_removed = true;
    try std.testing.expectEqual(@as(usize, 1), countNonRemoved(&list));

    list.items[1].is_removed = true;
    try std.testing.expectEqual(@as(usize, 0), countNonRemoved(&list));
}

test "focused_output_idx stays valid after swapRemove" {
    var focused: ?usize = 0;

    {
        const output_idx: usize = 0;
        const output_list_len: usize = 2;
        if (focused) |foi| {
            if (foi == output_idx) {
                if (output_list_len > 1) {
                    focused = @min(output_idx, output_list_len - 2);
                } else {
                    focused = null;
                }
            } else if (foi > output_idx) {
                focused = foi - 1;
            }
        }
        try std.testing.expectEqual(@as(?usize, 0), focused);
    }

    focused = 0;
    {
        const output_idx: usize = 1;
        const output_list_len: usize = 2;
        if (focused) |foi| {
            if (foi == output_idx) {
                if (output_list_len > 1) {
                    focused = @min(output_idx, output_list_len - 2);
                } else {
                    focused = null;
                }
            } else if (foi > output_idx) {
                focused = foi - 1;
            }
        }
        try std.testing.expectEqual(@as(?usize, 0), focused);
    }

    focused = 0;
    {
        const output_idx: usize = 0;
        const output_list_len: usize = 1;
        if (focused) |foi| {
            if (foi == output_idx) {
                if (output_list_len > 1) {
                    focused = @min(output_idx, output_list_len - 2);
                } else {
                    focused = null;
                }
            } else if (foi > output_idx) {
                focused = foi - 1;
            }
        }
        try std.testing.expectEqual(@as(?usize, null), focused);
    }
}
