const std = @import("std");

const types = @import("types.zig");
const common = @import("layout/common.zig");

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
                    common.placeWindow(window, output.rectangle, config);
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
                    common.placeWindow(window, output.rectangle, config);
                    output_still_animating = true;
                } else {
                    window.current = finish;
                    common.placeWindow(window, output.rectangle, config);

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
