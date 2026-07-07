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

pub fn initialRectangle(non_exclusive: types.Rectangle, config: types.Config) types.Rectangle {
    const base_width: f32 = @floatFromInt(non_exclusive.width - config.horizontal_gap);
    const width_with_gap: i32 = @trunc(base_width * config.default_window_width);
    return .{
        .width = width_with_gap - config.horizontal_gap,
        .height = non_exclusive.height - 2 * config.vertical_gap,
        .x = non_exclusive.x + non_exclusive.width - width_with_gap,
        .y = non_exclusive.y + config.vertical_gap,
    };
}

pub fn centerRectangle(non_exclusive: types.Rectangle, config: types.Config) types.Rectangle {
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
