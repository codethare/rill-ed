const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const river = wayland.client.river;

const types = @import("types.zig");
const common = @import("layout/common.zig");
pub const initialRectangle = common.initialRectangle;
pub const centerRectangle = common.centerRectangle;
const scroller = @import("layout/scroller.zig");
const floating = @import("layout/floating.zig");

pub fn update(output_list: std.ArrayList(types.Output), config: *const types.Config) void {
    for (output_list.items) |*output| {
        for (&output.workspace_list, 0..) |*workspace, workspace_idx| {
            const workspace_offset = @as(i32, @intCast(workspace_idx)) -
                @as(i32, @intCast(output.focused_workspace_idx));
            const y_offset = workspace_offset * output.rectangle.height;

            switch (workspace.layout) {
                .floating => floating.apply(workspace, output, y_offset),
                .scroller => scroller.apply(workspace, output, config, y_offset),
            }
        }

        output.is_animating = false;
        for (output.workspace_list) |workspace| {
            for (workspace.window_list.items) |window| {
                if (window.start != null or window.finish != null) {
                    output.is_animating = true;
                    break;
                }
            }
        }
    }
}

pub fn apply(
    allocator: Allocator,
    wm: *types.WindowManager,
    river_seat: *river.SeatV1,
) void {
    const config = wm.getConfig();

    for (wm.pending_windows.items) |*pending| {
        if (pending.initialized) continue;
        const window = pending.river_window;
        if (config.no_csd) window.useSsd();
        window.setTiled(common.edges);
        window.proposeDimensions(0, 0);
        window.hide();
        pending.initialized = true;
    }

    const output_list = &wm.output_list;
    const focused_output_idx = &wm.focused_output_idx;

    var needs_update = false;

    var output_idx = output_list.items.len;
    while (output_idx > 0) {
        output_idx -= 1;
        const output = &output_list.items[output_idx];

        if (output.is_removed) {
            // Count surviving (non-removed) outputs to decide migration vs
            // detachment strategy.
            var survivors: usize = 0;
            var survivor_idx: ?usize = null;
            for (output_list.items, 0..) |o, i| {
                if (!o.is_removed) {
                    survivors += 1;
                    survivor_idx = i;
                }
            }

            if (survivors > 0) {
                // Migrate windows to a surviving output. Must happen inside
                // the manage sequence (here). The event handler only sets
                // is_removed=true.
                const target = &output_list.items[survivor_idx.?];
                for (&output.workspace_list, &target.workspace_list) |*src_ws, *dst_ws| {
                    // Exit fullscreen on source windows before moving them.
                    for (src_ws.window_list.items) |window| {
                        if (window.is_fullscreen) window.river_window.exitFullscreen();
                    }
                    while (src_ws.window_list.items.len > 0) {
                        var window = src_ws.window_list.orderedRemove(0);
                        if (window.former_output_name) |old_name| allocator.free(old_name);
                        window.former_output_name = if (output.name) |name|
                            allocator.dupe(u8, name) catch null
                        else
                            null;
                        dst_ws.window_list.append(allocator, window) catch {
                            if (window.former_output_name) |n| allocator.free(n);
                            window.river_window.destroy();
                        };
                        if (dst_ws.focused_window_idx == null) {
                            dst_ws.focused_window_idx = dst_ws.window_list.items.len - 1;
                        }
                    }
                    src_ws.focused_window_idx = null;
                }
            } else {
                // No surviving outputs — preserve workspaces so they can be
                // restored when an output with the same name reappears.
                if (output.name) |name| {
                    const detached = types.DetachedOutput{
                        .workspace_list = output.workspace_list,
                        .focused_workspace_idx = output.focused_workspace_idx,
                    };
                    // On success: workspaces move to detached_outputs; zero source.
                    // On OOM: workspaces stay in output; cleanup loop below handles them.
                    if (wm.detached_outputs.put(name, detached)) {
                        output.workspace_list = [_]types.Workspace{.{}} ** 10;
                    } else |_| {}
                }
            }

            // Clean up any windows remaining in the output's workspaces.
            // After successful migration, workspaces are empty.
            // After successful detachment, workspaces were zeroed.
            // After OOM during detachment, this closes windows as fallback.
            for (&output.workspace_list) |*workspace| {
                for (workspace.window_list.items) |window| {
                    if (window.former_output_name) |n| allocator.free(n);
                    window.river_window.close();
                }
                workspace.window_list.deinit(allocator);
            }

            if (output.name) |name| allocator.free(name);
            if (output.wl_output) |wl_output| wl_output.destroy();
            if (output.river_layer_shell_output) |layer_shell_output| layer_shell_output.destroy();
            if (wm.river_window_manager != null) output.river_output.destroy();

            if (focused_output_idx.*) |foi| {
                if (foi == output_idx) {
                    if (output_list.items.len > 1) {
                        focused_output_idx.* = @min(output_idx, output_list.items.len - 2);
                    } else {
                        focused_output_idx.* = null;
                    }
                } else if (foi > output_idx) {
                    focused_output_idx.* = foi - 1;
                }
            }

            // When the last output is removed, the previously focused window
            // proxy and workspace pointer are no longer meaningful.
            if (focused_output_idx.* == null) {
                wm.last_focused_window = null;
                wm.previous_workspace = null;
            }

            _ = output_list.swapRemove(output_idx);
            needs_update = true;
            continue;
        }

        for (output.workspace_list) |workspace| {
            for (workspace.window_list.items) |*window| {
                const was_fullscreen = window.start != null and
                    window.start.?.x == output.rectangle.x and
                    window.start.?.y == output.rectangle.y and
                    window.start.?.width == output.rectangle.width and
                    window.start.?.height == output.rectangle.height;
                if (was_fullscreen) window.river_window.exitFullscreen();

                if (window.is_closing) window.river_window.close();
            }
        }
    }

    // Restore workspaces (with windows) that were detached when an output was
    // removed. Match by output name so windows return to the correct display
    // even if the compositor re-creates the output with a new river_output_v1.
    var restored_any = false;
    for (wm.output_list.items) |*output| {
        if (output.is_removed) continue;
        const name = output.name orelse continue;
        if (wm.detached_outputs.fetchRemove(name)) |kv| {
            allocator.free(kv.key);
            for (&output.workspace_list, 0..) |*workspace, ws_idx| {
                workspace.window_list.deinit(allocator);
                workspace.* = kv.value.workspace_list[ws_idx];
            }
            output.focused_workspace_idx = kv.value.focused_workspace_idx;
            // The previous output's compositor-side state was destroyed on
            // removal; reset sent_* caches so show/proposeDimensions/setBorders
            // are re-issued for the fresh output.
            for (&output.workspace_list) |*workspace| {
                for (workspace.window_list.items) |*window| {
                    window.sent_visible = null;
                    window.sent_current = null;
                    window.sent_clip = null;
                    window.sent_border_focused = null;
                    window.sent_border_width = null;
                }
            }
            restored_any = true;
        }
    }

    // Migrate windows back to the output whose name matches their
    // former_output_name. This restores windows to their original output
    // when it reappears (e.g. DPMS on after screen lock). Runs inside the
    // manage sequence so exitFullscreen/destroy calls are protocol-legal.
    for (wm.output_list.items, 0..) |*dst_output, dst_idx| {
        if (dst_output.is_removed) continue;
        const dst_name = dst_output.name orelse continue;

        for (wm.output_list.items, 0..) |*src_output, src_idx| {
            if (src_idx == dst_idx) continue;
            if (src_output.is_removed) continue;

            for (&src_output.workspace_list, &dst_output.workspace_list) |*src_ws, *dst_ws| {
                var i: usize = src_ws.window_list.items.len;
                while (i > 0) {
                    i -= 1;
                    const former = src_ws.window_list.items[i].former_output_name orelse continue;
                    if (!std.mem.eql(u8, former, dst_name)) continue;

                    var moved = src_ws.window_list.orderedRemove(i);
                    allocator.free(moved.former_output_name.?);
                    moved.former_output_name = null;
                    dst_ws.window_list.insert(allocator, 0, moved) catch {
                        moved.river_window.destroy();
                        continue;
                    };
                    if (dst_ws.focused_window_idx == null) dst_ws.focused_window_idx = 0;
                    if (src_ws.focused_window_idx) |fwi| {
                        if (fwi >= i) {
                            src_ws.focused_window_idx = if (fwi > 0) fwi - 1 else null;
                        }
                    }
                    restored_any = true;
                }
            }
        }
    }

    if (needs_update or restored_any) update(wm.output_list, config);

    applyFocusAndBorders(wm, river_seat);

    // When output focus moves to a different output (new output added, output
    // removed, or focus-output keybinding), warp the pointer to the focused
    // output's center. This matches the behavior of niri and hyprland and
    // prevents the cursor from staying trapped on a disabled or newly-connected
    // display.
    if (wm.needs_pointer_warp) {
        wm.needs_pointer_warp = false;
        if (wm.focused_output_idx) |idx| {
            const target = &wm.output_list.items[idx];
            river_seat.pointerWarp(
                target.rectangle.x + @divTrunc(target.rectangle.width, 2),
                target.rectangle.y + @divTrunc(target.rectangle.height, 2),
            );
        }
    }
}

/// Set border colors and keyboard focus to match the current focused
/// window/output. Safe to call every frame: redundant border and focus requests
/// are skipped so IME clients are not disrupted.
pub fn colorToRiver(c: types.Color) struct { r: u32, g: u32, b: u32, a: u32 } {
    var r: f32 = @floatFromInt(c.r);
    var g: f32 = @floatFromInt(c.g);
    var b: f32 = @floatFromInt(c.b);

    r = c.a * r / 255;
    g = c.a * g / 255;
    b = c.a * b / 255;

    const max: f64 = @floatFromInt(std.math.maxInt(u32));
    return .{
        .r = @intFromFloat(r * max),
        .g = @intFromFloat(g * max),
        .b = @intFromFloat(b * max),
        .a = @intFromFloat(c.a * max),
    };
}

pub fn applyFocusAndBorders(
    wm: *types.WindowManager,
    river_seat: *river.SeatV1,
) void {
    const config = wm.getConfig();
    const unfocused_color = colorToRiver(config.border.unfocused_color);
    const focused_color = colorToRiver(config.border.focused_color);

    const foi = wm.focused_output_idx orelse return;

    for (wm.output_list.items, 0..) |*output, output_idx| {
        if (output.is_removed) continue;

        for (output.workspace_list, 0..) |workspace, workspace_idx| {
            for (workspace.window_list.items, 0..) |*window, window_idx| {
                const is_focused = output_idx == foi and
                    workspace_idx == output.focused_workspace_idx and
                    window_idx == workspace.focused_window_idx;

                if (window.sent_border_focused == null or
                    window.sent_border_focused.? != is_focused or
                    window.sent_border_width == null or
                    window.sent_border_width.? != config.border.width)
                {
                    const color = if (is_focused) focused_color else unfocused_color;
                    window.river_window.setBorders(
                        common.edges,
                        config.border.width,
                        color.r,
                        color.g,
                        color.b,
                        color.a,
                    );
                    window.sent_border_focused = is_focused;
                    window.sent_border_width = config.border.width;
                }

                if (!is_focused) continue;
                window.river_node.placeTop();
            }
        }

        if (output_idx != foi) continue;
        if (output.river_layer_shell_output) |layer_shell_output| {
            layer_shell_output.setDefault();
        }
    }

    // Only send focus commands when the target actually changes. Unconditional
    // clear_focus/focus_window cycles deactivate input method clients such as
    // fcitx5 and kwim on every layout pass.
    if (wm.layer_shell_focus == .exclusive) {
        return;
    }

    // Skip focus management while the session is locked (ext-session-lock-v1).
    // The lock surface has exclusive keyboard focus managed by the compositor;
    // any focusWindow/clearFocus requests from rill-ed would be wasted or
    // could leave stale last_focused_window state on unlock.
    if (wm.session_locked) return;

    const desired_focus: ?*river.WindowV1 = blk: {
        const output = &wm.output_list.items[foi];
        const workspace = &output.workspace_list[output.focused_workspace_idx];
        const fwi = workspace.focused_window_idx orelse break :blk null;
        break :blk workspace.window_list.items[fwi].river_window;
    };

    if (desired_focus != wm.last_focused_window) {
        if (desired_focus) |window| {
            river_seat.focusWindow(window);
        } else if (wm.layer_shell_focus != .non_exclusive) {
            river_seat.clearFocus();
        }
        wm.last_focused_window = desired_focus;
    }
}

test "focused_output_idx stays valid after swapRemove" {
    var focused: ?usize = 0;

    {
        const output_idx: usize = 0;
        const output_list_len: usize = 2;
        if (focused) |foi| {
            if (foi == output_idx) {
                if (output_list_len > 1) {
                    focused = @min(output_idx, output_list_len - 2);
                } else {
                    focused = null;
                }
            } else if (foi > output_idx) {
                focused = foi - 1;
            }
        }
        try std.testing.expectEqual(@as(?usize, 0), focused);
    }

    focused = 0;
    {
        const output_idx: usize = 1;
        const output_list_len: usize = 2;
        if (focused) |foi| {
            if (foi == output_idx) {
                if (output_list_len > 1) {
                    focused = @min(output_idx, output_list_len - 2);
                } else {
                    focused = null;
                }
            } else if (foi > output_idx) {
                focused = foi - 1;
            }
        }
        try std.testing.expectEqual(@as(?usize, 0), focused);
    }

    focused = 0;
    {
        const output_idx: usize = 0;
        const output_list_len: usize = 1;
        if (focused) |foi| {
            if (foi == output_idx) {
                if (output_list_len > 1) {
                    focused = @min(output_idx, output_list_len - 2);
                } else {
                    focused = null;
                }
            } else if (foi > output_idx) {
                focused = foi - 1;
            }
        }
        try std.testing.expectEqual(@as(?usize, null), focused);
    }
}
