const std = @import("std");

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("../types.zig");

pub const edges = river.WindowV1.Edges{
    .top = true,
    .bottom = true,
    .left = true,
    .right = true,
};

pub fn initialRectangle(non_exclusive: types.Rectangle, config: *const types.Config) types.Rectangle {
    const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
    const width_with_gap: i32 = @trunc(base_width * config.default_window_width);
    return .{
        .width = width_with_gap - config.horizontal_gap,
        .height = non_exclusive.height - 2 * config.vertical_gap,
        .x = non_exclusive.x + non_exclusive.width - width_with_gap,
        .y = non_exclusive.y + config.vertical_gap,
    };
}

pub fn centerRectangle(non_exclusive: types.Rectangle, config: *const types.Config) types.Rectangle {
    const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
    const width_with_gap: i32 = @trunc(base_width * config.default_window_width);
    const w = width_with_gap - config.horizontal_gap;
    const h = non_exclusive.height - 2 * config.vertical_gap;
    return .{
        .width = w,
        .height = h,
        .x = non_exclusive.x + @divTrunc(non_exclusive.width - w, 2),
        .y = non_exclusive.y + config.vertical_gap,
    };
}

pub fn skipIfAtRest(window: *types.Window) void {
    const finish = window.finish orelse return;
    if (finish.eql(window.current) and
        window.sent_current != null and
        window.sent_current.?.eql(window.current))
    {
        window.start = null;
        window.finish = null;
    }
}

pub fn placeWindow(
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
        clip_height = @min(window_bottom - output_top, output_rectangle.height);
    } else if (output_bottom > window_top and output_bottom < window_bottom) {
        clip_height = window_bottom - output_top;
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
