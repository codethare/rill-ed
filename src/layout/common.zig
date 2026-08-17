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
    // 16:9 floating window: height derives from the width proportion.
    const h = @divTrunc(w * 9, 16);
    return .{
        .width = w,
        .height = h,
        .x = non_exclusive.x + @divTrunc(non_exclusive.width - w, 2),
        .y = non_exclusive.y + @divTrunc(non_exclusive.height - h, 2),
    };
}

/// Keyboard move step for floating windows, logical pixels (matches niri's
/// DIRECTIONAL_MOVE_PX; niri also hardcodes it rather than exposing config).
pub const floating_move_step: i32 = 50;

/// Translate a floating window by (dx, dy), clamped so it stays fully on the output.
pub fn moveFloatingWindow(window: *types.Window, output: *const types.Output, dx: i32, dy: i32) void {
    const left = output.rectangle.x;
    const right = output.rectangle.x + output.rectangle.width;
    const top = output.rectangle.y;
    const bottom = output.rectangle.y + output.rectangle.height;
    window.floating.x = std.math.clamp(window.floating.x + dx, left, right - window.floating.width);
    window.floating.y = std.math.clamp(window.floating.y + dy, top, bottom - window.floating.height);
}

/// Resize a floating window by (dw, dh), top-left anchored, clamped to output and min_size.
pub fn resizeFloatingWindow(window: *types.Window, output: *const types.Output, dw: i32, dh: i32, min_size: i32) void {
    const right = output.rectangle.x + output.rectangle.width;
    const bottom = output.rectangle.y + output.rectangle.height;
    window.floating.width = std.math.clamp(window.floating.width + dw, min_size, right - window.floating.x);
    window.floating.height = std.math.clamp(window.floating.height + dh, min_size, bottom - window.floating.y);
}

/// Expand/shrink a floating window on all four sides, keeping its center fixed,
/// clamped to the output and min_size.
pub fn scaleFloatingWindow(window: *types.Window, output: *const types.Output, dw: i32, dh: i32, min_size: i32) void {
    const left = output.rectangle.x;
    const right = output.rectangle.x + output.rectangle.width;
    const top = output.rectangle.y;
    const bottom = output.rectangle.y + output.rectangle.height;

    const new_width = std.math.clamp(window.floating.width + dw, min_size, right - left);
    const new_height = std.math.clamp(window.floating.height + dh, min_size, bottom - top);

    const cx = window.floating.x + @divTrunc(window.floating.width, 2);
    const cy = window.floating.y + @divTrunc(window.floating.height, 2);

    window.floating.width = new_width;
    window.floating.height = new_height;
    window.floating.x = std.math.clamp(cx - @divTrunc(new_width, 2), left, right - new_width);
    window.floating.y = std.math.clamp(cy - @divTrunc(new_height, 2), top, bottom - new_height);
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

test "floating move and resize clamp to output bounds" {
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
    var window: types.Window = .{
        .river_window = undefined,
        .river_node = undefined,
        .proportion = 0.5,
        .is_fullscreen = false,
        .is_floating = true,
        .is_closing = false,
        .floating = .{ .x = 100, .y = 100, .width = 800, .height = 600 },
        .current = .{ .x = 100, .y = 100, .width = 800, .height = 600 },
        .start = null,
        .finish = null,
    };

    moveFloatingWindow(&window, &output, -floating_move_step, floating_move_step);
    try std.testing.expectEqual(@as(i32, 50), window.floating.x);
    try std.testing.expectEqual(@as(i32, 150), window.floating.y);

    // Clamp at left/top edge.
    moveFloatingWindow(&window, &output, -1000, -1000);
    try std.testing.expectEqual(@as(i32, 0), window.floating.x);
    try std.testing.expectEqual(@as(i32, 0), window.floating.y);

    // Clamp at right/bottom edge.
    moveFloatingWindow(&window, &output, 100000, 100000);
    try std.testing.expectEqual(@as(i32, 1920 - 800), window.floating.x);
    try std.testing.expectEqual(@as(i32, 1080 - 600), window.floating.y);

    // Grow past output edge: clamp to remaining space.
    resizeFloatingWindow(&window, &output, 100000, 100000, 6);
    try std.testing.expectEqual(@as(i32, 1920 - window.floating.x), window.floating.width);
    try std.testing.expectEqual(@as(i32, 1080 - window.floating.y), window.floating.height);

    // Shrink past min_size: clamp to min_size.
    resizeFloatingWindow(&window, &output, -100000, -100000, 6);
    try std.testing.expectEqual(@as(i32, 6), window.floating.width);
    try std.testing.expectEqual(@as(i32, 6), window.floating.height);
}

test "floating scale expands and shrinks on all four sides" {
    const output: types.Output = .{
        .river_output = undefined,
        .river_layer_shell_output = null,
        .name = null,
        .workspace_list = [_]types.Workspace{.{}} ** 10,
        .focused_workspace_idx = 0,
        .rectangle = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .non_exclusive = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
        .is_removed = false,
    };
    var window: types.Window = .{
        .river_window = undefined,
        .river_node = undefined,
        .proportion = 0.5,
        .is_fullscreen = false,
        .is_floating = true,
        .is_closing = false,
        .floating = .{ .x = 100, .y = 100, .width = 800, .height = 600 },
        .current = .{ .x = 100, .y = 100, .width = 800, .height = 600 },
        .start = null,
        .finish = null,
    };

    // Expand: center stays fixed, all four edges move outward.
    scaleFloatingWindow(&window, &output, 200, 100, 6);
    try std.testing.expectEqual(@as(i32, 1000), window.floating.width);
    try std.testing.expectEqual(@as(i32, 700), window.floating.height);
    try std.testing.expectEqual(@as(i32, 0), window.floating.x);
    try std.testing.expectEqual(@as(i32, 50), window.floating.y);

    // Shrink: center stays fixed, all four edges move inward.
    window.floating = .{ .x = 100, .y = 100, .width = 800, .height = 600 };
    scaleFloatingWindow(&window, &output, -200, -100, 6);
    try std.testing.expectEqual(@as(i32, 600), window.floating.width);
    try std.testing.expectEqual(@as(i32, 500), window.floating.height);
    try std.testing.expectEqual(@as(i32, 200), window.floating.x);
    try std.testing.expectEqual(@as(i32, 150), window.floating.y);

    // Grow past output: clamp to output size.
    window.floating = .{ .x = 100, .y = 100, .width = 800, .height = 600 };
    scaleFloatingWindow(&window, &output, 100000, 100000, 6);
    try std.testing.expectEqual(@as(i32, 1920), window.floating.width);
    try std.testing.expectEqual(@as(i32, 1080), window.floating.height);
    try std.testing.expectEqual(@as(i32, 0), window.floating.x);
    try std.testing.expectEqual(@as(i32, 0), window.floating.y);

    // Shrink past min_size: clamp to min_size.
    window.floating = .{ .x = 100, .y = 100, .width = 800, .height = 600 };
    scaleFloatingWindow(&window, &output, -100000, -100000, 6);
    try std.testing.expectEqual(@as(i32, 6), window.floating.width);
    try std.testing.expectEqual(@as(i32, 6), window.floating.height);
    try std.testing.expectEqual(@as(i32, 497), window.floating.x);
    try std.testing.expectEqual(@as(i32, 397), window.floating.y);
}

test "centerRectangle is centered and 16:9" {
    const config: types.Config = .{ .default_window_width = 0.5 };
    const rect = centerRectangle(.{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, &config);

    // 16:9 within integer truncation.
    try std.testing.expect(@abs(rect.width * 9 - rect.height * 16) <= 15);
    // Centered and inside the output.
    try std.testing.expectEqual(@divTrunc(1920 - rect.width, 2), rect.x);
    try std.testing.expectEqual(@divTrunc(1080 - rect.height, 2), rect.y);
    try std.testing.expect(rect.x >= 0 and rect.y >= 0);
    try std.testing.expect(rect.x + rect.width <= 1920 and rect.y + rect.height <= 1080);
}
