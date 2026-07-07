const types = @import("../types.zig");

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
}
