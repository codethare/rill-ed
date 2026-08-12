const std = @import("std");

const types = @import("../types.zig");
const common = @import("common.zig");

pub fn apply(
    workspace: *types.Workspace,
    output: *types.Output,
    config: *const types.Config,
    y_offset: i32,
) void {
    for (workspace.window_list.items) |*window| {
        if (window.is_floating) {
            window.finish = window.floating;
            window.finish.?.y += y_offset;
            window.start = window.current;
        }
    }

    const focused_window_idx = workspace.focused_window_idx orelse return;
    const window_count = workspace.window_list.items.len;

    // Floating windows take no space in the strip; only tiled windows count
    // for the single-window fill and .single centering below.
    var tiled_count: usize = 0;
    for (workspace.window_list.items) |*window| {
        if (!window.is_floating) tiled_count += 1;
    }

    const should_center = switch (config.center_focused_window) {
        .never => false,
        .always => true,
        .single => tiled_count == 1,
    };

    var rectangle: types.Rectangle = undefined;

    const focused_is_floating = workspace.window_list.items[focused_window_idx].is_floating;
    if (!focused_is_floating) {
        const focused_window = &workspace.window_list.items[focused_window_idx];
        focusedWindowLayout(focused_window, &rectangle, output, config, y_offset, should_center);
        focused_window.finish = rectangle;

        // Unfocused windows to the right of focused
        rectangle.x += rectangle.width + config.horizontal_gap;
        for (workspace.window_list.items[focused_window_idx + 1 ..]) |*window| {
            if (window.is_floating) continue;
            unfocusedWindowLayout(window, &rectangle, output, config, y_offset);
            window.finish = rectangle;
            rectangle.x += rectangle.width + config.horizontal_gap;
        }

        // Unfocused windows to the left of focused
        rectangle.x = focused_window.finish.?.x;
        var window_idx = focused_window_idx;
        while (window_idx > 0) {
            window_idx -= 1;
            const window = &workspace.window_list.items[window_idx];
            if (window.is_floating) continue;
            unfocusedWindowLayout(window, &rectangle, output, config, y_offset);
            rectangle.x -= config.horizontal_gap + rectangle.width;
            window.finish = rectangle;
        }
    } else {
        // Focused window is floating: tile non-floating windows from the first one.
        // Keep anchor at its current.x (no left-edge clamp) so the strip preserves
        // its scroll position instead of jumping back to the leftmost window.
        const anchor_idx: ?usize = blk: {
            for (workspace.window_list.items, 0..) |*w, i| {
                if (!w.is_floating) break :blk i;
            }
            break :blk null;
        };
        if (anchor_idx == null) return;

        const anchor = &workspace.window_list.items[anchor_idx.?];
        const non_exclusive = output.non_exclusive;
        const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
        const width_with_gap: i32 = @trunc(base_width * anchor.proportion);

        rectangle = .{
            .width = width_with_gap - config.horizontal_gap,
            .height = non_exclusive.height - 2 * config.vertical_gap,
            .x = anchor.current.x,
            .y = non_exclusive.y + config.vertical_gap + y_offset,
        };

        if (should_center) {
            rectangle.x = non_exclusive.x +
                @divTrunc(non_exclusive.width, 2) - @divTrunc(rectangle.width, 2);
        }

        if (anchor.is_fullscreen) {
            rectangle = output.rectangle;
            rectangle.y += y_offset;
        }

        anchor.start = anchor.current;
        anchor.finish = rectangle;

        var i: usize = (anchor_idx.? + 1) % window_count;
        while (i != anchor_idx.?) : (i = (i + 1) % window_count) {
            const window = &workspace.window_list.items[i];
            if (window.is_floating) continue;
            rectangle.x += rectangle.width + config.horizontal_gap;
            unfocusedWindowLayout(window, &rectangle, output, config, y_offset);
            window.finish = rectangle;
        }
    }

    if (!should_center) snapToEdge(
        workspace.window_list,
        output.non_exclusive,
        config.horizontal_gap,
    );

    for (workspace.window_list.items) |*window| common.skipIfAtRest(window);
}

fn focusedWindowLayout(
    window: *types.Window,
    rectangle: *types.Rectangle,
    output: *types.Output,
    config: *const types.Config,
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
    config: *const types.Config,
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

test "floating window frees its slot; last tiled window keeps proportion" {
    const alloc = std.testing.allocator;
    const config: types.Config = .{};
    var output: types.Output = .{
        .river_output = undefined,
        .river_layer_shell_output = null,
        .name = null,
        .workspace_list = [_]types.Workspace{.{}} ** 10,
        .focused_workspace_idx = 0,
        .rectangle = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .non_exclusive = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .is_removed = false,
    };
    const ws = &output.workspace_list[0];
    for (0..2) |_| {
        try ws.window_list.append(alloc, .{
            .river_window = undefined,
            .river_node = undefined,
            .proportion = 0.5,
            .is_fullscreen = false,
            .is_floating = false,
            .is_closing = false,
            .floating = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .current = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .start = null,
            .finish = null,
        });
    }
    defer ws.window_list.deinit(alloc);
    ws.focused_window_idx = 1;

    apply(ws, &output, &config, 0);
    for (ws.window_list.items) |*w| {
        w.current = w.finish.?;
        w.sent_current = w.finish.?;
        w.start = null;
        w.finish = null;
    }

    // Toggle the focused window floating (mirrors the keybinding handler:
    // current is NOT snapped to floating, so the layout animates).
    const b = &ws.window_list.items[1];
    b.is_floating = true;
    b.floating = .{ .x = 460, .y = 190, .width = 1000, .height = 700 };

    apply(ws, &output, &config, 0);

    // The remaining tiled window keeps its stored proportion; new windows
    // do not change an existing column's width.
    const a = &ws.window_list.items[0];
    const base_width: f32 = @floatFromInt(output.non_exclusive.width - config.horizontal_gap);
    const expected_width_with_gap: i32 = @trunc(base_width * a.proportion);
    const a_rect = a.finish orelse a.current;
    try std.testing.expectEqual(
        expected_width_with_gap - config.horizontal_gap,
        a_rect.width,
    );
    // The floating window keeps its floating rectangle.
    try std.testing.expect(b.finish.?.eql(b.floating));
    // Stored proportions are untouched so un-floating restores the split.
    try std.testing.expectEqual(@as(f32, 0.5), a.proportion);
}

test "spawn floating while focus scrolled-right preserves strip position" {
    const alloc = std.testing.allocator;
    const config: types.Config = .{};
    var output: types.Output = .{
        .river_output = undefined,
        .river_layer_shell_output = null,
        .name = null,
        .workspace_list = [_]types.Workspace{.{}} ** 10,
        .focused_workspace_idx = 0,
        .rectangle = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .non_exclusive = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .is_removed = false,
    };
    const ws = &output.workspace_list[0];
    for (0..3) |_| {
        try ws.window_list.append(alloc, .{
            .river_window = undefined,
            .river_node = undefined,
            .proportion = 0.34,
            .is_fullscreen = false,
            .is_floating = false,
            .is_closing = false,
            .floating = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .current = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .start = null,
            .finish = null,
        });
    }
    defer ws.window_list.deinit(alloc);
    ws.focused_window_idx = 2;

    apply(ws, &output, &config, 0);
    for (ws.window_list.items) |*w| {
        w.current = w.finish.?;
        w.sent_current = w.finish.?;
        w.start = null;
        w.finish = null;
    }

    const before_0_x = ws.window_list.items[0].current.x;
    const before_1_x = ws.window_list.items[1].current.x;
    const before_2_x = ws.window_list.items[2].current.x;

    try ws.window_list.append(alloc, .{
        .river_window = undefined,
        .river_node = undefined,
        .proportion = 0.5,
        .is_fullscreen = false,
        .is_floating = true,
        .is_closing = false,
        .floating = .{ .x = 460, .y = 190, .width = 1000, .height = 700 },
        .current = .{ .x = 460, .y = 190, .width = 1000, .height = 700 },
        .start = null,
        .finish = null,
    });
    ws.focused_window_idx = 3;

    apply(ws, &output, &config, 0);

    const after_0_finish = ws.window_list.items[0].finish orelse ws.window_list.items[0].current;
    const after_1_finish = ws.window_list.items[1].finish orelse ws.window_list.items[1].current;
    const after_2_finish = ws.window_list.items[2].finish orelse ws.window_list.items[2].current;

    try std.testing.expectEqual(before_0_x, after_0_finish.x);
    try std.testing.expectEqual(before_1_x, after_1_finish.x);
    try std.testing.expectEqual(before_2_x, after_2_finish.x);
}

fn snapToEdge(
    window_list: std.ArrayList(types.Window),
    non_exclusive: types.Rectangle,
    gap: i32,
) void {
    if (window_list.items.len == 0) return;

    // Find first and last non-floating windows for head/tail
    var head_window: ?*types.Window = null;
    for (window_list.items) |*window| {
        if (!window.is_floating) {
            head_window = window;
            break;
        }
    }
    const head = head_window orelse return;
    const head_finish = head.finish orelse return;

    var tail_window: ?*types.Window = null;
    var idx: usize = window_list.items.len;
    while (idx > 0) {
        idx -= 1;
        if (!window_list.items[idx].is_floating) {
            tail_window = &window_list.items[idx];
            break;
        }
    }
    const tail = tail_window orelse return;
    const tail_finish = tail.finish orelse return;

    var head_distance: ?i32 = null;
    const left = non_exclusive.x + gap;
    if (head_finish.x > left) head_distance = head_finish.x - left;

    var tail_distance: ?i32 = null;
    const right = non_exclusive.x + non_exclusive.width - gap;
    const tail_end = tail_finish.x + tail_finish.width;
    if (tail_end < right) tail_distance = @min(right - tail_end, left - head_finish.x);

    for (window_list.items) |*window| {
        if (window.is_floating) continue;
        const x = &window.finish.?.x;
        if (head_distance) |distance| {
            x.* -= distance;
        } else if (tail_distance) |distance| {
            x.* += distance;
        }
    }
}

