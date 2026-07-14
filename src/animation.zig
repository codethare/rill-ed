const std = @import("std");

const types = @import("types.zig");

pub fn apply(
    output_list: std.ArrayList(types.Output),
    focused_output_idx: usize,
    config: types.Config,
    start_time: i64,
    now: i64,
) types.Status {
    const duration = config.animation_duration;
    if (duration == 0) {
        // Instant layout — jump to finish for all windows
        for (output_list.items, 0..) |*output, output_idx| {
            for (output.workspace_list, 0..) |workspace, workspace_idx| {
                for (workspace.window_list.items, 0..) |*window, window_idx| {
                    const finish = window.finish orelse continue;
                    window.current = finish;
                    placeWindow(window, output.rectangle, config);
                    if (window.is_fullscreen) {
                        const is_focused = output_idx == focused_output_idx and
                            workspace_idx == output.focused_workspace_idx and
                            window_idx == workspace.focused_window_idx;
                        if (is_focused) window.river_window.fullscreen(output.river_output);
                        window.river_window.informFullscreen();
                    } else {
                        window.river_window.informNotFullscreen();
                    }
                    window.start = null;
                    window.finish = null;
                }
            }
        }
        return .none;
    }
    const is_last_frame = now - start_time >= duration;

    const elapsed: f32 = @floatFromInt(now - start_time);
    const progress = elapsed / @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);

    for (output_list.items, 0..) |*output, output_idx| {
        for (output.workspace_list, 0..) |workspace, workspace_idx| {
            for (workspace.window_list.items, 0..) |*window, window_idx| {
                const start = window.start orelse continue;
                const finish = window.finish orelse continue;

                if (!is_last_frame) {
                    const width_distance: f32 = @floatFromInt(finish.width - start.width);
                    const height_distance: f32 = @floatFromInt(finish.height - start.height);
                    const x_distance: f32 = @floatFromInt(finish.x - start.x);
                    const y_distance: f32 = @floatFromInt(finish.y - start.y);

                    const width_progress: i32 = @trunc(width_distance * eased);
                    const height_progress: i32 = @trunc(height_distance * eased);
                    const x_progress: i32 = @trunc(x_distance * eased);
                    const y_progress: i32 = @trunc(y_distance * eased);

                    window.current = .{
                        .width = start.width + width_progress,
                        .height = start.height + height_progress,
                        .x = start.x + x_progress,
                        .y = start.y + y_progress,
                    };
                    placeWindow(window, output.rectangle, config);
                } else {
                    window.current = finish;
                    placeWindow(window, output.rectangle, config);

                    if (window.is_fullscreen) {
                        const is_focused = output_idx == focused_output_idx and
                            workspace_idx == output.focused_workspace_idx and
                            window_idx == workspace.focused_window_idx;

                        if (is_focused) window.river_window.fullscreen(output.river_output);
                        window.river_window.informFullscreen();
                    } else {
                        window.river_window.informNotFullscreen();
                    }

                    window.start = null;
                    window.finish = null;
                }
            }
        }
    }

    if (is_last_frame) {
        return .none;
    } else {
        return .{ .animation = start_time };
    }
}

fn placeWindow(
    window: *types.Window,
    output_rectangle: types.Rectangle,
    config: types.Config,
) void {
    var border_width = config.border.width;
    if (window.is_fullscreen) border_width = 0;
    const geo = types.borderGeometry(window.border_edges, border_width);

    window.river_window.proposeDimensions(
        @max(0, window.current.width - geo.dw),
        @max(0, window.current.height - geo.dh),
    );
    window.river_node.setPosition(
        window.current.x + geo.dx,
        window.current.y + geo.dy,
    );

    const window_left = window.current.x;
    const window_right = window.current.x + window.current.width;
    const window_top = window.current.y;
    const window_bottom = window.current.y + window.current.height;

    const output_left = output_rectangle.x;
    const output_right = output_rectangle.x + output_rectangle.width;
    const output_top = output_rectangle.y;
    const output_bottom = output_rectangle.y + output_rectangle.height;

    if (output_left >= window_right or output_right <= window_left or
        output_top >= window_bottom or output_bottom <= window_top)
    {
        window.river_window.hide();
    } else {
        window.river_window.show();
    }

    var clip_width = window.current.width;
    var clip_height = window.current.height;
    var clip_x: i32 = 0;
    var clip_y: i32 = 0;

    if (output_left < window_right and output_left > window_left) {
        clip_x = output_left - window_left;
        clip_width = @min(window_right - output_left, output_rectangle.width);
    } else if (output_right > window_left and output_right < window_right) {
        clip_width = output_right - window_left;
    }

    if (output_top < window_bottom and output_top > window_top) {
        clip_y = output_top - window_top;
        clip_height = window_bottom - output_top;
    } else if (output_bottom > window_top and output_bottom < window_bottom) {
        clip_height = output_bottom - window_top;
    }

    window.river_window.setClipBox(
        clip_x - geo.dx,
        clip_y - geo.dy,
        clip_width,
        clip_height,
    );
}
