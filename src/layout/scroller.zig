const std = @import("std");

const types = @import("../types.zig");

pub fn apply(
    workspace: *types.Workspace,
    output: *types.Output,
    config: types.Config,
    y_offset: i32,
) void {
    const focused_window_idx = workspace.focused_window_idx orelse return;
    const focused_window = &workspace.window_list.items[focused_window_idx];
    const window_count = workspace.window_list.items.len;
    var rectangle: types.Rectangle = undefined;

    const should_center = switch (config.center_focused_window) {
        .never => false,
        .always => true,
        .single => window_count == 1,
    };

    focusedWindowLayout(focused_window, &rectangle, output, config, y_offset, should_center, window_count);
    focused_window.finish = rectangle;

    // Unfocused windows to the right of focused
    rectangle.x += rectangle.width + config.horizontal_gap;
    for (workspace.window_list.items[focused_window_idx + 1 ..]) |*window| {
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
        unfocusedWindowLayout(window, &rectangle, output, config, y_offset);
        rectangle.x -= config.horizontal_gap + rectangle.width;
        window.finish = rectangle;
    }

    if (!should_center) snapToEdge(
        workspace.window_list,
        output.non_exclusive,
        config.horizontal_gap,
    );
}

fn focusedWindowLayout(
    window: *types.Window,
    rectangle: *types.Rectangle,
    output: *types.Output,
    config: types.Config,
    y_offset: i32,
    should_center: bool,
    window_count: usize,
) void {
    const non_exclusive = output.non_exclusive;
    const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
    // ponytail: single window fills the usable width; keep stored proportion
    // untouched so adding a second window restores the prior split sizes.
    const proportion = if (window_count == 1) @as(f32, 1.0) else window.proportion;
    const width_with_gap: i32 = @trunc(base_width * proportion);

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
