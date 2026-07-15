const std = @import("std");

const types = @import("types.zig");

pub fn apply(
    output_list: std.ArrayList(types.Output),
    focused_output_idx: usize,
    config: *const types.Config,
    start_time: i64,
    now: i64,
) types.Status {
    const duration = config.animation_duration;
    if (duration == 0) {
        // Instant layout — jump to finish for all windows on animating outputs.
        for (output_list.items, 0..) |*output, output_idx| {
            if (!output.is_animating) continue;
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
            output.is_animating = false;
        }
        return .none;
    }
    const is_last_frame = now - start_time >= duration;

    const elapsed: f32 = @floatFromInt(now - start_time);
    const progress = elapsed / @as(f32, @floatFromInt(duration));
    const eased = 1 - std.math.pow(f32, 1 - progress, 3);

    var any_animating = false;
    for (output_list.items, 0..) |*output, output_idx| {
        if (!output.is_animating) continue;
        var output_still_animating = false;

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
                    output_still_animating = true;
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

        if (output_still_animating) {
            any_animating = true;
        } else {
            output.is_animating = false;
        }
    }

    if (is_last_frame or !any_animating) {
        return .none;
    } else {
        return .{ .animation = start_time };
    }
}

fn placeWindow(
    window: *types.Window,
    output_rectangle: types.Rectangle,
    config: *const types.Config,
) void {
    var border_width = config.border.width;
    if (window.is_fullscreen) border_width = 0;

    if (window.sent_current == null or !window.sent_current.?.eql(window.current)) {
        window.river_window.proposeDimensions(
            @max(0, window.current.width - 2 * border_width),
            @max(0, window.current.height - 2 * border_width),
        );
        window.river_node.setPosition(
            window.current.x + border_width,
            window.current.y + border_width,
        );
        window.sent_current = window.current;
    }

    const window_left = window.current.x;
    const window_right = window.current.x + window.current.width;
    const window_top = window.current.y;
    const window_bottom = window.current.y + window.current.height;

    const output_left = output_rectangle.x;
    const output_right = output_rectangle.x + output_rectangle.width;
    const output_top = output_rectangle.y;
    const output_bottom = output_rectangle.y + output_rectangle.height;

    const visible = !(output_left >= window_right or output_right <= window_left or
        output_top >= window_bottom or output_bottom <= window_top);
    if (window.sent_visible == null or window.sent_visible.? != visible) {
        if (visible) window.river_window.show() else window.river_window.hide();
        window.sent_visible = visible;
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

    const clip = types.Rectangle{
        .x = clip_x - border_width,
        .y = clip_y - border_width,
        .width = clip_width,
        .height = clip_height,
    };
    if (window.sent_clip == null or !window.sent_clip.?.eql(clip)) {
        window.river_window.setClipBox(clip.x, clip.y, clip.width, clip.height);
        window.sent_clip = clip;
    }
}
