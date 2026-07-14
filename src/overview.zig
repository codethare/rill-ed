const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const layout = @import("layout.zig");

/// Collect all windows from all workspaces on the current output into
/// workspace 0 and arrange them in a grid.
pub fn enter(
    allocator: std.mem.Allocator,
    wm: *types.WindowManager,
) !void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];

    var origins: std.ArrayList(types.OverviewState.Origin) = .empty;

    var total: usize = 0;
    for (output.workspace_list) |ws| {
        total += ws.window_list.items.len;
    }

    if (total == 0) return;

    // Move all windows to workspace 0, recording origins.
    const target_ws = &output.workspace_list[0];
    for (&output.workspace_list, 0..) |*src_ws, ws_idx| {
        if (ws_idx == 0) {
            for (src_ws.window_list.items) |*w| {
                if (w.is_fullscreen) {
                    w.is_fullscreen = false;
                    w.river_window.exitFullscreen();
                }
            }
            for (src_ws.window_list.items, 0..) |_, win_idx| {
                try origins.append(allocator, .{
                    .workspace_idx = 0,
                    .window_idx = win_idx,
                });
            }
            continue;
        }
        while (src_ws.window_list.items.len > 0) {
            const window = src_ws.window_list.orderedRemove(0);
            if (window.is_fullscreen) window.river_window.exitFullscreen();
            try origins.append(allocator, .{
                .workspace_idx = ws_idx,
                .window_idx = src_ws.focused_window_idx orelse 0,
            });
            try target_ws.window_list.append(allocator, window);
        }
        src_ws.focused_window_idx = null;
    }

    // Set up the overview workspace as floating and calculate grid layout.
    target_ws.is_floating = true;
    target_ws.layout = .floating;
    target_ws.focused_window_idx = 0;

    const total_windows = target_ws.window_list.items.len;
    const cols = gridColumns(total_windows, &output.non_exclusive);

    const positions = gridPositions(
        allocator,
        total_windows,
        cols,
        output.non_exclusive,
    );
    defer allocator.free(positions);

    for (target_ws.window_list.items, 0..) |*window, i| {
        window.floating = positions[i];
        window.finish = positions[i];
        window.start = window.current;
    }

    output.focused_workspace_idx = 0;
    output.workspace_list[0].focused_window_idx = 0;

    wm.overview_state = .{
        .origins = origins,
        .highlighted = 0,
        .columns = cols,
        .output_idx = output_idx,
        .previous_workspace = if (wm.previous_workspace) |pw|
            .{ .output_idx = pw.output_idx, .workspace_idx = pw.workspace_idx }
        else
            null,
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

    wm.focused_output_idx = ov_state.output_idx;
    const output = &wm.output_list.items[ov_state.output_idx];
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
    const output = &wm.output_list.items[state.output_idx];
    const overview_ws = &output.workspace_list[0];

    var i: usize = overview_ws.window_list.items.len;
    while (i > 0) {
        i -= 1;
        const origin = state.origins.items[i];
        if (origin.workspace_idx == 0) continue;

        var moved_window = overview_ws.window_list.orderedRemove(i);
        moved_window.floating = layout.centerRectangle(output.non_exclusive, wm.getConfig());
        moved_window.current = moved_window.floating;

        const dst = &output.workspace_list[origin.workspace_idx];
        const insert_at = @min(origin.window_idx, dst.window_list.items.len);
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

fn gridPositions(
    allocator: std.mem.Allocator,
    total: usize,
    cols: usize,
    rect: types.Rectangle,
) []types.Rectangle {
    const rows = (total + cols - 1) / cols;

    const gap: i32 = 10;
    const cell_w = @divTrunc(rect.width - gap * (@as(i32, @intCast(cols)) + 1), @as(i32, @intCast(cols)));
    const cell_h = @divTrunc(rect.height - gap * (@as(i32, @intCast(rows)) + 1), @as(i32, @intCast(rows)));

    const positions = allocator.alloc(types.Rectangle, total) catch @panic("OOM");

    for (0..total) |i| {
        const row: i32 = @intCast(i / cols);
        const col: i32 = @intCast(i % cols);
        positions[i] = .{
            .x = rect.x + gap + col * (cell_w + gap),
            .y = rect.y + gap + row * (cell_h + gap),
            .width = cell_w,
            .height = cell_h,
        };
    }
    return positions;
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

    const unfocused_color = config.border.unfocused_color.toRiverColor();
    const focused_color = config.border.focused_color.toRiverColor();

    const ws = &output.workspace_list[0];
    types.updateBorderEdges(ws);

    for (ws.window_list.items, 0..) |*window, idx| {
        window.river_window.exitFullscreen();

        if (idx == state.highlighted) {
            window.river_window.setBorders(
                window.border_edges,
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
                window.border_edges,
                config.border.width,
                unfocused_color.r,
                unfocused_color.g,
                unfocused_color.b,
                unfocused_color.a,
            );
        }
    }
}
