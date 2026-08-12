const std = @import("std");

const types = @import("../types.zig");
const common = @import("common.zig");

pub fn apply(
    workspace: *types.Workspace,
    output: *types.Output,
    y_offset: i32,
) void {
    for (workspace.window_list.items) |*window| {
        if (window.is_fullscreen) {
            window.finish = output.rectangle;
        } else {
            window.finish = window.floating;
        }
        window.start = window.current;
        window.finish.?.y += y_offset;
    }

    for (workspace.window_list.items) |*window| common.skipIfAtRest(window);
}

test "new floating window animates from right edge to centered rect" {
    const alloc = std.testing.allocator;
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
    ws.layout = .floating;

    // Mirrors window.add(): current starts at initialRectangle (right edge),
    // floating is the centered target rect.
    try ws.window_list.append(alloc, .{
        .river_window = undefined,
        .river_node = undefined,
        .proportion = 0.5,
        .is_fullscreen = false,
        .is_floating = true,
        .is_closing = false,
        .floating = .{ .x = 460, .y = 90, .width = 1000, .height = 900 },
        .current = .{ .x = 920, .y = 90, .width = 1000, .height = 900 },
        .start = null,
        .finish = null,
    });
    defer ws.window_list.deinit(alloc);

    apply(ws, &output, 0);

    const w = &ws.window_list.items[0];
    try std.testing.expect(w.start != null and w.finish != null);
    // start != finish so animation.zig interpolates instead of popping.
    try std.testing.expect(!w.start.?.eql(w.finish.?));
    try std.testing.expect(w.finish.?.eql(w.floating));
}
