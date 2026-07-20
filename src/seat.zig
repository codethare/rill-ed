const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const river = wayland.client.river;

const layout = @import("layout.zig");
const overview = @import("overview.zig");
const types = @import("types.zig");

pub fn seatListener(
    _: *river.SeatV1,
    event: river.SeatV1.Event,
    wm: *types.WindowManager,
) void {
    const focus = wm.currentFocus() orelse return;
    const output = focus.output;
    const window = focus.window;

    switch (event) {
        .window_interaction => |interaction| {
            // During overview, clicking a window selects it.
            if (wm.overview_state) |*state| {
                const ov_output = &wm.output_list.items[state.output_idx];
                const ov_ws = &ov_output.workspace_list[0];
                for (ov_ws.window_list.items, 0..) |w, idx| {
                    if (w.river_window == interaction.window) {
                        overview.selectIndex(wm.allocator, wm, idx);
                        layout.update(wm.output_list, wm.getConfig());
                        wm.status = .layout;
                        return;
                    }
                }
                return;
            }

            if (interaction.window == window.river_window) return;

            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                for (target_workspace.window_list.items, 0..) |target_window, target_window_idx| {
                    if (target_window.river_window != interaction.window) continue;

                    wm.focused_output_idx = target_output_idx;
                    target_workspace.focused_window_idx = target_window_idx;

                    if (target_output_idx != focus.output_idx) {
                        wm.previous_workspace = .{
                            .output_idx = focus.output_idx,
                            .workspace_idx = focus.workspace_idx,
                        };
                    }

                    layout.update(wm.output_list, wm.getConfig());
                    wm.status = .layout;
                    return;
                }
            }
        },
        .op_delta => |delta| {
            const start = window.start orelse return;

            const output_left = output.rectangle.x;
            const output_right = output.rectangle.x + output.rectangle.width;
            const output_top = output.rectangle.y;
            const output_bottom = output.rectangle.y + output.rectangle.height;

            switch (wm.status.pointer_action) {
                .move_window => {
                    window.floating.x = std.math.clamp(
                        start.x + delta.dx,
                        output_left,
                        output_right - window.current.width,
                    );
                    window.floating.y = std.math.clamp(
                        start.y + delta.dy,
                        output_top,
                        output_bottom - window.current.height,
                    );
                },
                .resize_window => {
                    window.floating.width = std.math.clamp(
                        start.width + delta.dx,
                        0,
                        output_right - window.current.x,
                    );
                    window.floating.height = std.math.clamp(
                        start.height + delta.dy,
                        0,
                        output_bottom - window.current.y,
                    );
                },
            }
            window.current = window.floating;
        },
        .op_release => {
            wm.status = .none;
            window.start = null;
        },
        else => {},
    }
}

pub fn setupPointerBindings(allocator: Allocator, wm: *types.WindowManager) !void {
    for (wm.pointer_binding_list.items) |binding| binding.river_pointer_binding.destroy();
    wm.pointer_binding_list.clearRetainingCapacity();

    for (wm.getConfig().pointer_bindings) |binding| {
        const pointer_binding = try wm.river_seat.?.getPointerBinding(
            @intFromEnum(binding.button),
            binding.modifiers,
        );
        try wm.pointer_binding_list.append(
            allocator,
            .{ .river_pointer_binding = pointer_binding, .action = binding.action },
        );
        pointer_binding.setListener(*types.WindowManager, pointerBindingListener, wm);
        pointer_binding.enable();
    }
}

fn pointerBindingListener(
    pointer_binding: *river.PointerBindingV1,
    event: river.PointerBindingV1.Event,
    wm: *types.WindowManager,
) void {
    for (wm.pointer_binding_list.items) |binding| {
        if (binding.river_pointer_binding != pointer_binding) continue;
        switch (event) {
            .pressed => {
                const focus = wm.currentFocus() orelse return;
                const window = focus.window;
                if (!window.is_floating) return;
                if (window.is_fullscreen) return;
                window.start = window.current;

                wm.status = .{ .pointer_action = binding.action };
            },
            else => {},
        }
        return;
    }
}

pub fn layerShellSeatListener(
    _: *river.LayerShellSeatV1,
    event: river.LayerShellSeatV1.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .focus_exclusive => {
            wm.layer_shell_focus = .exclusive;
            wm.status = .layout;
        },
        .focus_non_exclusive => {
            wm.layer_shell_focus = .non_exclusive;
            wm.status = .layout;
        },
        .focus_none => {
            wm.layer_shell_focus = .none;
            // Exclusive layer-shell focus was revoked; invalidate the
            // stale focus cache so focusWindow is re-issued.
            wm.last_focused_window = null;
            wm.needs_refocus = true;
            wm.status = .layout;
            if (wm.river_window_manager) |window_manager| window_manager.manageDirty();
        },
    }
}

pub fn pointerAction(
    output_list: *std.ArrayList(types.Output),
    focused_output_idx: usize,
    config: *const types.Config,
) void {
    const output = output_list.items[focused_output_idx];
    const workspace = output.workspace_list[output.focused_workspace_idx];
    const window_idx = workspace.focused_window_idx orelse return;
    if (window_idx >= workspace.window_list.items.len) return;
    const window = workspace.window_list.items[window_idx];

    window.river_window.setClipBox(0, 0, 0, 0);

    var border_width = config.border.width;
    if (window.is_fullscreen) border_width = 0;

    window.river_window.proposeDimensions(
        @max(0, window.current.width - 2 * border_width),
        @max(0, window.current.height - 2 * border_width),
    );
    window.river_node.setPosition(
        window.current.x + border_width,
        window.current.y + border_width,
    );
}
