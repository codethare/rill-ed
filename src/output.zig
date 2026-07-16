const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const river = wayland.client.river;

const layout = @import("layout.zig");
const types = @import("types.zig");

pub fn add(
    allocator: Allocator,
    river_output: *river.OutputV1,
    wm: *types.WindowManager,
) !void {
    const output = types.Output{
        .river_output = river_output,
        .river_layer_shell_output = getLayerShellOutput(river_output, wm),
        .workspace_list = [_]types.Workspace{.{}} ** 10,
        .focused_workspace_idx = 0,
        .rectangle = undefined,
        .non_exclusive = undefined,
        .is_removed = false,
    };
    const had_previous_output = wm.output_list.items.len > 0;
    try wm.output_list.append(allocator, output);
    wm.focused_output_idx = wm.output_list.items.len - 1;
    // A newly-connected output becomes focused automatically. Warp the
    // pointer to it on the next layout pass so the cursor follows focus,
    // matching niri and hyprland behavior.
    if (had_previous_output) wm.needs_pointer_warp = true;
    river_output.setListener(*types.WindowManager, outputListener, wm);

    // If the previous output was removed without any surviving display (e.g. TTY
    // switch-away), its workspaces were preserved. Restore them on the new output.
    if (wm.detached_workspaces) |*detached| {
        const restored = &wm.output_list.items[wm.focused_output_idx.?];
        for (&restored.workspace_list, 0..) |*workspace, ws_idx| {
            // Restore workspace-level state only; river will send fresh
            // river_window_v1 proxies for the windows after TTY switch-back.
            workspace.is_floating = detached[ws_idx].is_floating;
            workspace.layout = detached[ws_idx].layout;
        }

        // The detached window lists were emptied before detaching; just free
        // any residual capacity.
        for (detached) |*workspace| {
            workspace.window_list.deinit(wm.allocator);
        }
        wm.detached_workspaces = null;

        wm.status = .layout;
        if (wm.river_window_manager) |window_manager| window_manager.manageDirty();
    }
}

fn getLayerShellOutput(
    river_output: *river.OutputV1,
    wm: *types.WindowManager,
) ?*river.LayerShellOutputV1 {
    const layer_shell = wm.river_layer_shell orelse {
        std.debug.print("Failed to find layer shell\n", .{});
        return null;
    };
    const layer_shell_output = layer_shell.getOutput(river_output) catch {
        std.debug.print("Failed to get layer shell output\n", .{});
        return null;
    };

    layer_shell_output.setListener(*types.WindowManager, layerShellOutputListener, wm);
    return layer_shell_output;
}

fn outputListener(
    river_output: *river.OutputV1,
    event: river.OutputV1.Event,
    wm: *types.WindowManager,
) void {
    for (wm.output_list.items, 0..) |*output, idx| {
        if (output.river_output != river_output) continue;
        switch (event) {
            .dimensions => |dimensions| {
                output.rectangle.width = dimensions.width;
                output.rectangle.height = dimensions.height;
                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;
            },
            .position => |position| {
                output.rectangle.x = position.x;
                output.rectangle.y = position.y;
            },
            .removed => {
                output.is_removed = true;
                wm.status = .layout;

                // Count active (non-removed) outputs, not total items.len
                var active_count: usize = 0;
                for (wm.output_list.items) |o| {
                    if (!o.is_removed) active_count += 1;
                }
                if (active_count == 0) {
                    // Last surviving output was removed. Detach workspace state
                    // (without stale window objects) and remove it immediately so
                    // a replacement output doesn't migrate dead proxies.
                    if (wm.detached_workspaces) |*detached| {
                        for (detached) |*workspace| {
                            workspace.window_list.deinit(wm.allocator);
                        }
                    }
                    for (&output.workspace_list) |*workspace| {
                        for (workspace.window_list.items) |window| {
                            window.river_window.destroy();
                        }
                        workspace.window_list.deinit(wm.allocator);
                    }
                    wm.detached_workspaces = output.workspace_list;

                    if (output.river_layer_shell_output) |layer_shell_output| {
                        layer_shell_output.destroy();
                    }
                    output.river_output.destroy();
                    _ = wm.output_list.orderedRemove(idx);

                    wm.focused_output_idx = null;
                    wm.previous_workspace = null;
                    wm.last_focused_window = null;
                    return;
                } else if (wm.focused_output_idx) |foi| {
                    if (foi == idx) {
                        // pnytl: current focus was this removed output → first alive
                        wm.focused_output_idx = null;
                        for (wm.output_list.items, 0..) |o, i| {
                            if (!o.is_removed) {
                                wm.focused_output_idx = i;
                                break;
                            }
                        }
                        // Warp the cursor on the next layout pass so it does
                        // not remain trapped on the disabled output.
                        wm.needs_pointer_warp = true;
                    }
                }

                const previous_workspace = wm.previous_workspace orelse return;
                if (previous_workspace.output_idx == idx) {
                    wm.previous_workspace = null;
                }
            },
            else => {},
        }
        return;
    }
}

fn layerShellOutputListener(
    layer_shell_output: *river.LayerShellOutputV1,
    event: river.LayerShellOutputV1.Event,
    wm: *types.WindowManager,
) void {
    for (wm.output_list.items) |*output| {
        if (output.river_layer_shell_output != layer_shell_output) continue;
        switch (event) {
            .non_exclusive_area => |area| {
                output.non_exclusive = .{
                    .width = area.width,
                    .height = area.height,
                    .x = area.x,
                    .y = area.y,
                };
                layout.update(wm.output_list, wm.getConfig());
                wm.status = .layout;
            },
        }
        return;
    }
}
