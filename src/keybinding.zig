const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wayland = @import("wayland");
const xkbcommon = @import("xkbcommon");
const river = wayland.client.river;

const config = @import("config.zig");
const layout = @import("layout.zig");
const overview = @import("overview.zig");
const spawn = @import("spawn.zig");
const types = @import("types.zig");

pub fn setupKeybindings(allocator: Allocator, wm: *types.WindowManager) !void {
    for (wm.xkb_binding_list.items) |binding| binding.river_xkb_binding.destroy();
    wm.xkb_binding_list.clearRetainingCapacity();

    const xkb_bindings = wm.river_xkb_bindings orelse {
        std.debug.print("Failed to find xkb bindings\n", .{});
        return;
    };

    for (wm.getConfig().keybindings) |keybinding| {
        const keysym = parseKey(keybinding.key) orelse {
            std.debug.print("Failed to parse key\n", .{});
            continue;
        };
        const xkb_binding = try xkb_bindings.getXkbBinding(
            wm.river_seat.?,
            @intFromEnum(keysym),
            keybinding.modifiers,
        );

        try wm.xkb_binding_list.append(
            allocator,
            .{ .river_xkb_binding = xkb_binding, .action = keybinding.action },
        );
        xkb_binding.setListener(*types.WindowManager, xkbBindingListener, wm);
        xkb_binding.enable();
    }
}

fn parseKey(key: [:0]const u8) ?xkbcommon.Keysym {
    const keysym = xkbcommon.Keysym.fromName(key, .case_insensitive);
    if (keysym != .NoSymbol) return keysym;
    return null;
}

test "validate default keybindings" {
    for (types.default_keybindings) |keybinding| {
        if (parseKey(keybinding.key) == null) {
            std.debug.print("Keysym '{s}' is not valid\n", .{keybinding.key});
        }
        try std.testing.expect(parseKey(keybinding.key) != null);
    }
}

fn xkbBindingListener(
    xkb_binding: *river.XkbBindingV1,
    event: river.XkbBindingV1.Event,
    wm: *types.WindowManager,
) void {
    if (wm.status == .pointer_action) return;

    // During overview, intercept all key events for navigation.
    if (wm.overview_state != null and event == .pressed) {
        overviewKeyPressed(wm, xkb_binding) catch |err| {
            std.debug.print("Overview key failed: {}\n", .{err});
        };
        return;
    }

    for (wm.xkb_binding_list.items) |binding| {
        if (binding.river_xkb_binding != xkb_binding) continue;
        switch (event) {
            .pressed => {
                keybindingPressed(
                    wm.allocator,
                    wm.io,
                    binding.action,
                    wm,
                    wm.environ_map,
                ) catch |err| {
                    std.debug.print("Keybinding's action failed: {}\n", .{err});
                };
            },
            else => {},
        }
        return;
    }
}

fn keybindingPressed(
    allocator: Allocator,
    io: Io,
    action: types.KeybindingAction,
    wm: *types.WindowManager,
    environ_map: std.process.Environ.Map,
) !void {
    const output_idx = wm.focused_output_idx orelse return;
    const output = &wm.output_list.items[output_idx];
    const workspace_idx = output.focused_workspace_idx;
    const workspace = &output.workspace_list[workspace_idx];

    action_switch: switch (action) {
        .close_window => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.is_closing = true;
        },
        .toggle_fullscreen => {
            const window_idx = workspace.focused_window_idx orelse return;
            const window = &workspace.window_list.items[window_idx];
            window.is_fullscreen = !window.is_fullscreen;
        },
        .toggle_maximize_column => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            window.proportion = if (window.proportion == 1.0) 0.5 else 1.0;
        },
        .adjust_window_width => |increment| {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            if (window.is_fullscreen) return;

            const gap = wm.getConfig().horizontal_gap;
            const base_width: f32 = @floatFromInt(output.non_exclusive.width - gap);
            const width_with_gap: i32 = @trunc(base_width * (window.proportion + increment));
            if (width_with_gap - gap < 2 * wm.getConfig().border.width) return;

            window.proportion += increment;
        },
        .set_window_width => |proportion| {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            var window = &workspace.window_list.items[window_idx];
            window.proportion = proportion;
        },
        .focus_window_left => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) return;
            workspace.focused_window_idx = window_idx - 1;
        },
        .focus_window_or_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (workspace.is_floating or window_idx == 0) {
                continue :action_switch .focus_output_left;
            }
            continue :action_switch .focus_window_left;
        },
        .focus_window_right => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) return;
            workspace.focused_window_idx = window_idx + 1;
        },
        .focus_window_or_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (workspace.is_floating or window_idx == workspace.window_list.items.len - 1) {
                continue :action_switch .focus_output_right;
            }
            continue :action_switch .focus_window_right;
        },
        .move_window_left => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) return;
            std.mem.swap(
                types.Window,
                &workspace.window_list.items[window_idx],
                &workspace.window_list.items[window_idx - 1],
            );
            workspace.focused_window_idx = window_idx - 1;
        },
        .move_window_right => {
            if (workspace.is_floating) return;
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) return;
            std.mem.swap(
                types.Window,
                &workspace.window_list.items[window_idx],
                &workspace.window_list.items[window_idx + 1],
            );
            workspace.focused_window_idx = window_idx + 1;
        },
        .move_window_left_or_to_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == 0) {
                continue :action_switch .move_window_to_output_left;
            }
            continue :action_switch .move_window_left;
        },
        .move_window_right_or_to_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            if (window_idx == workspace.window_list.items.len - 1) {
                continue :action_switch .move_window_to_output_right;
            }
            continue :action_switch .move_window_right;
        },
        .toggle_workspace_floating => {
                    const window_idx = workspace.focused_window_idx orelse return;
                    const window = &workspace.window_list.items[window_idx];
                    window.is_floating = !window.is_floating;
                    if (window.is_floating) {
                        window.floating = layout.centerRectangle(
                            output.non_exclusive,
                            wm.getConfig(),
                        );
                        window.current = window.floating;
                    }
                },
        .focus_workspace_above => {
            if (workspace_idx == 0) return;
            output.focused_workspace_idx -= 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_below => {
            if (workspace_idx == 9) return;
            output.focused_workspace_idx += 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .focus_output_above;
            }
            continue :action_switch .focus_workspace_above;
        },
        .focus_workspace_or_output_below => {
            if (workspace_idx == 9) {
                continue :action_switch .focus_output_below;
            }
            continue :action_switch .focus_workspace_below;
        },
        .focus_workspace_previous => {
            const previous = wm.previous_workspace orelse return;
            wm.focused_output_idx = previous.output_idx;
            const target_output = &wm.output_list.items[previous.output_idx];
            target_output.focused_workspace_idx = previous.workspace_idx;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_workspace_number => |number| {
            if (number == 0 or number > 10) return;
            if (workspace_idx == number - 1) return;
            output.focused_workspace_idx = number - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_above => {
            if (workspace_idx == 0) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_workspace = &output.workspace_list[workspace_idx - 1];

            try moveWindowToWorkspace(
                allocator,
                window_idx,
                workspace,
                target_workspace,
            );

            output.focused_workspace_idx = workspace_idx - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_below => {
            if (workspace_idx == 9) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_workspace = &output.workspace_list[workspace_idx + 1];

            try moveWindowToWorkspace(
                allocator,
                window_idx,
                workspace,
                target_workspace,
            );

            output.focused_workspace_idx = workspace_idx + 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .move_window_to_workspace_or_output_above => {
            if (workspace_idx == 0) {
                continue :action_switch .move_window_to_output_above;
            }
            continue :action_switch .move_window_to_workspace_above;
        },
        .move_window_to_workspace_or_output_below => {
            if (workspace_idx == 9) {
                continue :action_switch .move_window_to_output_below;
            }
            continue :action_switch .move_window_to_workspace_below;
        },
        .move_window_to_workspace_number => |number| {
            if (number == 0 or number > 10 or number - 1 == workspace_idx) return;
            const window_idx = workspace.focused_window_idx orelse return;
            const target_workspace = &output.workspace_list[number - 1];

            try moveWindowToWorkspace(
                allocator,
                window_idx,
                workspace,
                target_workspace,
            );

            output.focused_workspace_idx = number - 1;
            wm.previous_workspace = .{
                .output_idx = output_idx,
                .workspace_idx = workspace_idx,
            };
        },
        .focus_output_left => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.is_removed) continue;
                if (target_output.rectangle.x + target_output.rectangle.width !=
                    output.rectangle.x) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .focus_output_right => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.is_removed) continue;
                if (target_output.rectangle.x !=
                    output.rectangle.x + output.rectangle.width) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .focus_output_above => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.is_removed) continue;
                if (target_output.rectangle.y + target_output.rectangle.height !=
                    output.rectangle.y) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .focus_output_below => {
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.is_removed) continue;
                if (target_output.rectangle.y !=
                    output.rectangle.y + output.rectangle.height) continue;

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_left => {
            const window_idx = workspace.focused_window_idx orelse return;
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.is_removed) continue;
                if (target_output.rectangle.x + target_output.rectangle.width !=
                    output.rectangle.x) continue;

                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                try moveWindowToWorkspace(
                    allocator,
                    window_idx,
                    workspace,
                    target_workspace,
                );

                const target_window_idx = target_workspace.focused_window_idx.?;
                target_workspace.window_list.items[target_window_idx].floating =
                    layout.initialRectangle(target_output.non_exclusive, wm.getConfig());

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_right => {
            const window_idx = workspace.focused_window_idx orelse return;
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.is_removed) continue;
                if (target_output.rectangle.x !=
                    output.rectangle.x + output.rectangle.width) continue;

                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                try moveWindowToWorkspace(
                    allocator,
                    window_idx,
                    workspace,
                    target_workspace,
                );

                const target_window_idx = target_workspace.focused_window_idx.?;
                target_workspace.window_list.items[target_window_idx].floating =
                    layout.initialRectangle(target_output.non_exclusive, wm.getConfig());

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_above => {
            const window_idx = workspace.focused_window_idx orelse return;
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.is_removed) continue;
                if (target_output.rectangle.y + target_output.rectangle.height !=
                    output.rectangle.y) continue;

                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                try moveWindowToWorkspace(
                    allocator,
                    window_idx,
                    workspace,
                    target_workspace,
                );

                const target_window_idx = target_workspace.focused_window_idx.?;
                target_workspace.window_list.items[target_window_idx].floating =
                    layout.initialRectangle(target_output.non_exclusive, wm.getConfig());

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .move_window_to_output_below => {
            const window_idx = workspace.focused_window_idx orelse return;
            for (wm.output_list.items, 0..) |*target_output, target_output_idx| {
                if (target_output.is_removed) continue;
                if (target_output.rectangle.y !=
                    output.rectangle.y + output.rectangle.height) continue;

                const target_workspace =
                    &target_output.workspace_list[target_output.focused_workspace_idx];

                try moveWindowToWorkspace(
                    allocator,
                    window_idx,
                    workspace,
                    target_workspace,
                );

                const target_window_idx = target_workspace.focused_window_idx.?;
                target_workspace.window_list.items[target_window_idx].floating =
                    layout.initialRectangle(target_output.non_exclusive, wm.getConfig());

                wm.focused_output_idx = target_output_idx;
                wm.previous_workspace = .{
                    .output_idx = output_idx,
                    .workspace_idx = workspace_idx,
                };
            }
        },
        .exit => {
            wm.status = .exit;
            return;
        },
        .reload_config => {
            if (config.reload(allocator, io, environ_map, wm.config)) |_| {} else {
                std.debug.print("Config reload failed — keeping current config\n", .{});
                return;
            }

            if (wm.getConfig().cursor) |cursor| {
                wm.river_seat.?.setXcursorTheme(cursor.theme, cursor.size);
            }
            layout.update(wm.output_list, wm.getConfig());

            wm.status = .setup_bindings;
            return;
        },
        .enter_overview => {
            overview.enter(allocator, wm) catch |err| {
                std.debug.print("Failed to enter overview: {}\n", .{err});
                return;
            };
            if (wm.overview_state != null) {
                // layout already done by overview.enter, just request manage.
                wm.river_window_manager.?.manageDirty();
                return;
            }
        },
        .spawn => |command| {
            spawn.spawnDetached(allocator, command, environ_map);
            return;
        },
    }

    layout.update(wm.output_list, wm.getConfig());
    wm.status = .layout;
}

fn moveWindowToWorkspace(
    allocator: Allocator,
    window_idx: usize,
    workspace: *types.Workspace,
    target_workspace: *types.Workspace,
) !void {
    const window = workspace.window_list.orderedRemove(window_idx);

    if (workspace.window_list.items.len == 0) {
        workspace.focused_window_idx = null;
    } else if (window_idx != 0) {
        workspace.focused_window_idx = window_idx - 1;
    }

    var target_window_idx: usize = 0;
    if (target_workspace.focused_window_idx) |idx| target_window_idx = idx + 1;

    try target_workspace.window_list.insert(allocator, target_window_idx, window);
    target_workspace.focused_window_idx = target_window_idx;
}

fn overviewKeyPressed(
    wm: *types.WindowManager,
    xkb_binding: *river.XkbBindingV1,
) !void {
    for (wm.xkb_binding_list.items) |binding| {
        if (binding.river_xkb_binding != xkb_binding) continue;

        switch (binding.action) {
            // Toggle: pressing enter_overview again exits overview.
            .enter_overview => {
                overview.cancel(wm.allocator, wm);
                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;
                return;
            },
            // Escape / exit still cancels.
            .exit => {
                overview.cancel(wm.allocator, wm);
                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;
                return;
            },
            else => return,
        }
    }
}
