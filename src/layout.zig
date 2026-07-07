const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");

const edges = river.WindowV1.Edges{
    .top = true,
    .bottom = true,
    .left = true,
    .right = true,
};

pub var pending_windows: std.ArrayList(*river.WindowV1) = .empty;

pub fn update(output_list: std.ArrayList(types.Output), config: types.Config) void {
    for (output_list.items) |*output| {
        for (output.workspace_list, 0..) |workspace, workspace_idx| {
            const workspace_offset = @as(i32, @intCast(workspace_idx)) -
                @as(i32, @intCast(output.focused_workspace_idx));
            const y_offset = workspace_offset * output.rectangle.height;

            if (workspace.is_floating) {
                floatingLayout(workspace.window_list, output, y_offset);
                continue;
            }

            const focused_window_idx = workspace.focused_window_idx orelse continue;
            const focused_window = &workspace.window_list.items[focused_window_idx];
            var rectangle: types.Rectangle = undefined;

            const should_center = switch (config.center_focused_window) {
                .never => false,
                .always => true,
                .single => workspace.window_list.items.len == 1,
            };

            focusedWindowLayout(
                focused_window,
                &rectangle,
                output,
                config,
                y_offset,
                should_center,
            );
            focused_window.finish = rectangle;

            rectangle.x += rectangle.width + config.horizontal_gap;
            for (workspace.window_list.items[focused_window_idx + 1 ..]) |*window| {
                unfocusedWindowLayout(
                    window,
                    &rectangle,
                    output,
                    config,
                    y_offset,
                );
                window.finish = rectangle;
                rectangle.x += rectangle.width + config.horizontal_gap;
            }

            rectangle.x = focused_window.finish.?.x;
            var window_idx = focused_window_idx;
            while (window_idx > 0) {
                window_idx -= 1;
                const window = &workspace.window_list.items[window_idx];
                unfocusedWindowLayout(
                    window,
                    &rectangle,
                    output,
                    config,
                    y_offset,
                );
                rectangle.x -= config.horizontal_gap + rectangle.width;
                window.finish = rectangle;
            }

            if (!should_center) snapToEdge(
                workspace.window_list,
                output.non_exclusive,
                config.horizontal_gap,
            );
        }
    }
}

fn floatingLayout(
    window_list: std.ArrayList(types.Window),
    output: *types.Output,
    y_offset: i32,
) void {
    for (window_list.items) |*window| {
        if (window.is_fullscreen) {
            window.finish = output.rectangle;
        } else {
            window.finish = window.floating;
        }
        window.start = window.current;
        window.finish.?.y += y_offset;
    }
}

fn focusedWindowLayout(
    window: *types.Window,
    rectangle: *types.Rectangle,
    output: *types.Output,
    config: types.Config,
    y_offset: i32,
    should_center: bool,
) void {
    const non_exclusive = output.non_exclusive;
    const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
    const width_with_gap: i32 = @trunc(base_width * window.proportion);

    rectangle.* = .{
        .width = width_with_gap - config.horizontal_gap,
        .height = non_exclusive.height - 2 * config.vertical_gap,
        .x = window.current.x,
        .y = non_exclusive.y + config.vertical_gap + y_offset,
    };

    if (should_center) {
        rectangle.x = non_exclusive.x +
            @divTrunc(non_exclusive.width, 2) - @divTrunc(rectangle.width, 2);
    } else if (rectangle.x < non_exclusive.x + config.horizontal_gap) {
        rectangle.x = non_exclusive.x + config.horizontal_gap;
    } else if (rectangle.x + width_with_gap > non_exclusive.x + non_exclusive.width) {
        rectangle.x = @max(
            non_exclusive.x + non_exclusive.width - width_with_gap,
            non_exclusive.x + config.horizontal_gap,
        );
    }

    if (window.is_fullscreen) {
        rectangle.* = output.rectangle;
        rectangle.y += y_offset;
    }

    window.start = window.current;
}

fn unfocusedWindowLayout(
    window: *types.Window,
    rectangle: *types.Rectangle,
    output: *types.Output,
    config: types.Config,
    y_offset: i32,
) void {
    if (window.is_fullscreen) {
        rectangle.width = output.rectangle.width;
        rectangle.height = output.rectangle.height;
        rectangle.y = output.rectangle.y + y_offset;
    } else {
        const non_exclusive = output.non_exclusive;
        const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
        const width_with_gap: i32 = @trunc(base_width * window.proportion);

        rectangle.width = width_with_gap - config.horizontal_gap;
        rectangle.height = non_exclusive.height - 2 * config.vertical_gap;
        rectangle.y = non_exclusive.y + config.vertical_gap + y_offset;
    }
    window.start = window.current;
}

fn snapToEdge(
    window_list: std.ArrayList(types.Window),
    non_exclusive: types.Rectangle,
    gap: i32,
) void {
    if (window_list.items.len == 0) return;
    var head_distance: ?i32 = null;
    const head_finish = window_list.items[0].finish orelse return;
    const head = head_finish.x;
    const left = non_exclusive.x + gap;
    if (head > left) head_distance = head - left;

    var tail_distance: ?i32 = null;
    const tail_window = window_list.items[window_list.items.len - 1];
    const tail_finish = tail_window.finish orelse return;
    const tail = tail_finish.x + tail_finish.width;
    const right = non_exclusive.x + non_exclusive.width - gap;
    if (tail < right) tail_distance = @min(right - tail, left - head);

    for (window_list.items) |*window| {
        const x = &window.finish.?.x;
        if (head_distance) |distance| {
            x.* -= distance;
        } else if (tail_distance) |distance| {
            x.* += distance;
        }
    }
}

pub fn apply(
    allocator: Allocator,
    output_list: *std.ArrayList(types.Output),
    focused_output_idx: *?usize,
    config: types.Config,
    river_seat: *river.SeatV1,
) void {
    river_seat.clearFocus();

    for (pending_windows.items) |window| {
        if (config.no_csd) window.useSsd();
        window.setTiled(edges);
        window.proposeDimensions(0, 0);
    }

    // Count non-removed outputs to decide migration vs free-memory path
    const non_removed_count = countNonRemoved(output_list);

    var output_idx = output_list.items.len;
    while (output_idx > 0) {
        output_idx -= 1;
        const output = &output_list.items[output_idx];

        if (output.is_removed) {
            if (non_removed_count > 1) {
                // Multiple non-removed outputs remain: migrate windows
                const target_idx = if (output_idx > 0) output_idx - 1 else output_idx + 1;
                for (&output.workspace_list, 0..) |*src_ws, ws_idx| {
                    const target_ws = &output_list.items[target_idx].workspace_list[ws_idx];
                    const offset = target_ws.window_list.items.len;
                    for (src_ws.window_list.items) |window| {
                        if (window.is_fullscreen) window.river_window.exitFullscreen();
                        target_ws.window_list.append(allocator, window) catch continue;
                    }
                    if (src_ws.focused_window_idx) |fwi| {
                        target_ws.focused_window_idx = offset + fwi;
                    }
                    src_ws.window_list.deinit(allocator);
                }
            } else {
                // Only one non-removed output (or none) — free memory; river will re-send
                // window events if a replacement output appears (e.g. TTY switch-back).
                for (&output.workspace_list) |*workspace| {
                    for (workspace.window_list.items) |window| {
                        if (window.is_fullscreen) window.river_window.exitFullscreen();
                    }
                    workspace.window_list.deinit(allocator);
                }
            }

            // Adjust focused_output_idx for the removal
            if (focused_output_idx.*) |foi| {
                if (foi == output_idx) {
                    // Focused output being removed — pick first surviving, or null if none left
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

        const foi = focused_output_idx.* orelse continue;

        for (output.workspace_list, 0..) |workspace, workspace_idx| {
            for (workspace.window_list.items, 0..) |window, window_idx| {
                window.river_window.exitFullscreen();

                const unfocused_color = config.border.unfocused_color.toRiverColor();
                window.river_window.setBorders(
                    edges,
                    config.border.width,
                    unfocused_color.r,
                    unfocused_color.g,
                    unfocused_color.b,
                    unfocused_color.a,
                );

                if (window.is_closing) window.river_window.close();

                if (output_idx != foi) continue;
                if (workspace_idx != output.focused_workspace_idx) continue;
                if (window_idx != workspace.focused_window_idx) continue;

                const focused_color = config.border.focused_color.toRiverColor();
                window.river_window.setBorders(
                    edges,
                    config.border.width,
                    focused_color.r,
                    focused_color.g,
                    focused_color.b,
                    focused_color.a,
                );

                window.river_node.placeTop();
                river_seat.focusWindow(window.river_window);
            }
        }

        if (output_idx != foi) continue;
        if (output.river_layer_shell_output) |layer_shell_output| {
            layer_shell_output.setDefault();
        }
    }
}

fn countNonRemoved(output_list: *std.ArrayList(types.Output)) usize {
    var count: usize = 0;
    for (output_list.items) |output| {
        if (!output.is_removed) count += 1;
    }
    return count;
}

pub fn initialRectangle(
    non_exclusive: types.Rectangle,
    config: types.Config,
) types.Rectangle {
    const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
    const width_with_gap: i32 = @trunc(base_width * config.default_window_width);
    return .{
        .width = width_with_gap - config.horizontal_gap,
        .height = non_exclusive.height - 2 * config.vertical_gap,
        .x = non_exclusive.x + non_exclusive.width - width_with_gap,
        .y = non_exclusive.y + config.vertical_gap,
    };
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
    // Verify the focus-index adjustment logic: when the focused output is
    // removed, the index should shift to the first surviving output.
    var focused: ?usize = 0;

    // Simulate: output_list=[A(removed), B], focused=0
    // After removing A via swapRemove(0), list becomes [B], focused should become 0
    {
        const output_idx: usize = 0;
        const output_list_len: usize = 2; // len before swapRemove

        // Adjustment logic copied from apply()
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

    // Simulate: output_list=[B, A(removed)], focused=0
    // After removing A via swapRemove(1), focused stays 0
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

    // Simulate: only one output, focused=0, it gets removed
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
