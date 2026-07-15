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

    for (workspace.window_list.items) |*window| {
        const finish = window.finish orelse continue;
        if (finish.eql(window.current) and
            window.sent_current != null and
            window.sent_current.?.eql(window.current))
        {
            window.start = null;
            window.finish = null;
        }
    }
}
