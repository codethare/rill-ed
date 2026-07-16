const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const common = @import("layout/common.zig");
const types = @import("types.zig");
const layout = @import("layout.zig");

/// Collect all windows from all workspaces across all outputs into
/// workspace 0 of the focused output and arrange them in a grid.
pub fn enter(
    allocator: std.mem.Allocator,
    wm: *types.WindowManager,
) !void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];

    var origins: std.ArrayList(types.OverviewState.Origin) = .empty;

    // Count total windows across ALL outputs.
    var total: usize = 0;
    for (wm.output_list.items) |*out| {
        for (out.workspace_list) |ws| {
            total += ws.window_list.items.len;
        }
    }

    if (total == 0) return;

    // Move all windows from all outputs to workspace 0 of the focused output, recording origins.
    const target_ws = &output.workspace_list[0];
    for (wm.output_list.items, 0..) |*out, out_idx| {
        for (&out.workspace_list, 0..) |*src_ws, ws_idx| {
            if (out_idx == output_idx and ws_idx == 0) {
                for (src_ws.window_list.items) |*w| {
                    if (w.is_fullscreen) {
                        w.is_fullscreen = false;
                        w.river_window.exitFullscreen();
                    }
                }
                for (src_ws.window_list.items, 0..) |_, win_idx| {
                    try origins.append(allocator, .{
                        .output_idx = out_idx,
                        .workspace_idx = 0,
                        .window_idx = win_idx,
                    });
                }
                continue;
            }
            var window_idx: usize = 0;
            while (src_ws.window_list.items.len > 0) {
                const window = src_ws.window_list.orderedRemove(0);
                if (window.is_fullscreen) window.river_window.exitFullscreen();
                try origins.append(allocator, .{
                    .output_idx = out_idx,
                    .workspace_idx = ws_idx,
                    .window_idx = window_idx,
                });
                window_idx += 1;
                try target_ws.window_list.append(allocator, window);
            }
            src_ws.focused_window_idx = null;
        }
    }

    // Set up the overview workspace as floating and calculate grid layout.
    target_ws.is_floating = true;
    target_ws.layout = .floating;
    target_ws.focused_window_idx = 0;

    const total_windows = target_ws.window_list.items.len;
    const cols = gridColumns(total_windows, &output.non_exclusive);
    const rows = (total_windows + cols - 1) / cols;

    const gap: i32 = 10;
    const cell_w = @divTrunc(output.non_exclusive.width - gap * (@as(i32, @intCast(cols)) + 1), @as(i32, @intCast(cols)));
    const cell_h = @divTrunc(output.non_exclusive.height - gap * (@as(i32, @intCast(rows)) + 1), @as(i32, @intCast(rows)));

    for (target_ws.window_list.items, 0..) |*window, i| {
        const row: i32 = @intCast(i / cols);
        const col: i32 = @intCast(i % cols);
        const rect = types.Rectangle{
            .x = output.non_exclusive.x + gap + col * (cell_w + gap),
            .y = output.non_exclusive.y + gap + row * (cell_h + gap),
            .width = cell_w,
            .height = cell_h,
        };
        window.floating = rect;
        window.finish = rect;
        window.start = window.current;
    }

    output.focused_workspace_idx = 0;
    output.workspace_list[0].focused_window_idx = 0;

    wm.overview_state = .{
        .origins = origins,
        .highlighted = 0,
        .columns = cols,
        .output_idx = output_idx,
        .previous_workspace = blk: {
            if (wm.focused_output_idx) |focused_idx| {
                const focused_output = &wm.output_list.items[focused_idx];
                break :blk .{
                    .output_idx = focused_idx,
                    .workspace_idx = focused_output.focused_workspace_idx,
                };
            }
            break :blk null;
        },
    };

    wm.status = .overview;
}

/// Exit overview: restore windows to their original workspaces,
/// focus the selected window's workspace and the window itself.
pub fn select(
    allocator: std.mem.Allocator,
    wm: *types.WindowManager,
) void {
    const ov_state = wm.overview_state orelse return;
    const selected_idx = ov_state.highlighted;
    if (selected_idx >= ov_state.origins.items.len) {
        cancel(allocator, wm);
        return;
    }
    const origin = ov_state.origins.items[selected_idx];

    restoreWindows(allocator, wm, ov_state);
    wm.overview_state.?.origins.deinit(allocator);
    wm.overview_state = null;

    wm.focused_output_idx = origin.output_idx;
    const output = &wm.output_list.items[origin.output_idx];
    output.focused_workspace_idx = origin.workspace_idx;
    const ws = &output.workspace_list[origin.workspace_idx];
    ws.focused_window_idx = @min(origin.window_idx, ws.window_list.items.len -| 1);
}

/// Cancel overview: restore windows, focus the previously focused workspace.
pub fn cancel(
    allocator: std.mem.Allocator,
    wm: *types.WindowManager,
) void {
    const ov_state = wm.overview_state orelse return;
    const prev = ov_state.previous_workspace;
    restoreWindows(allocator, wm, ov_state);
    wm.overview_state.?.origins.deinit(allocator);
    wm.overview_state = null;

    if (prev) |p| {
        wm.focused_output_idx = p.output_idx;
        wm.output_list.items[p.output_idx].focused_workspace_idx = p.workspace_idx;
    }
}

/// Select the window at the given index (from mouse click).
pub fn selectIndex(
    allocator: std.mem.Allocator,
    wm: *types.WindowManager,
    index: usize,
) void {
    if (wm.overview_state) |*state| {
        state.highlighted = index;
    }
    select(allocator, wm);
}

fn restoreWindows(
    allocator: std.mem.Allocator,
    wm: *types.WindowManager,
    state: types.OverviewState,
) void {
    const overview_output = &wm.output_list.items[state.output_idx];
    const overview_ws = &overview_output.workspace_list[0];

    var i: usize = overview_ws.window_list.items.len;
    while (i > 0) {
        i -= 1;
        const origin = state.origins.items[i];
        if (origin.output_idx == state.output_idx and origin.workspace_idx == 0) continue;

        var moved_window = overview_ws.window_list.orderedRemove(i);
        const dst_output = &wm.output_list.items[origin.output_idx];
        moved_window.floating = layout.centerRectangle(dst_output.non_exclusive, wm.getConfig());
        moved_window.current = moved_window.floating;

        const dst = &dst_output.workspace_list[origin.workspace_idx];
        const insert_at: usize = 0;
        dst.window_list.insert(allocator, insert_at, moved_window) catch {
            moved_window.river_window.destroy();
        };
        if (dst.focused_window_idx == null) {
            dst.focused_window_idx = insert_at;
        }
    }

    overview_ws.is_floating = false;
    overview_ws.layout = .scroller;
    if (overview_ws.window_list.items.len > 0 and overview_ws.focused_window_idx == null) {
        overview_ws.focused_window_idx = 0;
    }
}

fn gridColumns(total: usize, rect: *const types.Rectangle) usize {
    if (total <= 1) return 1;
    const aspect: f32 = @as(f32, @floatFromInt(rect.width)) / @as(f32, @floatFromInt(@max(1, rect.height)));
    const cols_f: f32 = @sqrt(@as(f32, @floatFromInt(total)) * aspect);
    return @max(1, @as(usize, @intFromFloat(@ceil(cols_f))));
}

/// Apply border colors and focus for the overview state without recalculating layout.
pub fn applyBorders(
    wm: *types.WindowManager,
    river_seat: *river.SeatV1,
) void {
    if (wm.overview_state == null) return;
    const state = &wm.overview_state.?;
    const output = &wm.output_list.items[state.output_idx];
    const config = wm.getConfig();

    river_seat.clearFocus();

    const unfocused_color = layout.colorToRiver(config.border.unfocused_color);
    const focused_color = layout.colorToRiver(config.border.focused_color);

    const ws = &output.workspace_list[0];
    for (ws.window_list.items, 0..) |*window, idx| {
        window.river_window.exitFullscreen();

        if (idx == state.highlighted) {
            window.river_window.setBorders(
                common.edges,
                config.border.width,
                focused_color.r,
                focused_color.g,
                focused_color.b,
                focused_color.a,
            );
            window.river_node.placeTop();
            river_seat.focusWindow(window.river_window);
        } else {
            window.river_window.setBorders(
                common.edges,
                config.border.width,
                unfocused_color.r,
                unfocused_color.g,
                unfocused_color.b,
                unfocused_color.a,
            );
        }
    }
}
