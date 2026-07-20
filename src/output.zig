const std = @import("std");
const Allocator = std.mem.Allocator;

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

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
    const new_idx = wm.output_list.items.len - 1;
    wm.focused_output_idx = new_idx;
    // A newly-connected output becomes focused automatically. Warp the
    // pointer to it on the next layout pass so the cursor follows focus,
    // matching niri and hyprland behavior.
    if (had_previous_output) wm.needs_pointer_warp = true;
    river_output.setListener(*types.WindowManager, outputListener, wm);

    // Workspace and window restoration for reappearing outputs is handled by
    // layout.apply() inside the manage sequence. Output state is keyed by
    // output name so it is restored to the correct display even when the
    // compositor re-creates the output with a new river_output_v1.
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
            .wl_output => |data| {
                const wl_output = wm.registry.bind(data.name, wl.Output, 4) catch {
                    std.debug.print("Failed to bind wl_output\n", .{});
                    return;
                };
                output.wl_output = wl_output;
                wl_output.setListener(*types.WindowManager, wlOutputListener, wm);
            },
            .removed => {
                output.is_removed = true;
                wm.status = .layout;

                // All window management state modifications (migration,
                // detachment, destroy) are deferred to layout.apply(),
                // which runs inside the manage sequence. Calling them here
                // is a protocol error per river-window-management-v1:
                //   "Window management state may only be modified by the
                //    window manager as part of a manage sequence."
                // Violating this during swidle+waylock (DPMS off/on) causes
                // compositor disconnects and lost windows.

                // Count active (non-removed) outputs for focus adjustment.
                var active_count: usize = 0;
                for (wm.output_list.items) |o| {
                    if (!o.is_removed) active_count += 1;
                }

                // Adjust focus if the removed output was focused.
                // When surviving outputs exist, switch focus to one.
                // When it was the last output, leave focused_output_idx
                // alone so manage() doesn't return early — layout.apply()
                // nullifies it during cleanup inside the manage sequence.
                if (wm.focused_output_idx) |foi| {
                    if (foi == idx) {
                        if (active_count > 0) {
                            wm.focused_output_idx = null;
                            for (wm.output_list.items, 0..) |o, i| {
                                if (!o.is_removed) {
                                    wm.focused_output_idx = i;
                                    break;
                                }
                            }
                            wm.needs_pointer_warp = true;
                        }
                    }
                }

                // Clear previous_workspace if it pointed to the removed output.
                if (wm.previous_workspace) |pw| {
                    if (pw.output_idx == idx) wm.previous_workspace = null;
                }

                // Request a manage sequence so layout.apply() can migrate
                // windows to surviving outputs and clean up the removed
                // output inside the manage sequence as required by the
                // river-window-management-v1 protocol.
                if (wm.river_window_manager) |window_manager| window_manager.manageDirty();
            },
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

fn wlOutputListener(wl_output: *wl.Output, event: wl.Output.Event, wm: *types.WindowManager) void {
    const output = for (wm.output_list.items) |*o| {
        if (o.wl_output == wl_output) break o;
    } else return;

    switch (event) {
        .name => |data| {
            const name = std.mem.span(data.name);
            if (output.name) |old_name| wm.allocator.free(old_name);
            output.name = wm.allocator.dupe(u8, name) catch null;
            // Ensure the next manage sequence runs so layout.apply() can
            // restore any workspaces or windows keyed to this output name.
            wm.status = .layout;
            if (wm.river_window_manager) |window_manager| window_manager.manageDirty();
        },
        else => {},
    }
}

// migrateWindowsOut, migrateWindowsBack, and detachOutput are now in
// layout.zig so they run inside the manage sequence. See layout.zig's
// apply() for the is_removed output handling.

test {
    _ = std.testing.refAllDecls(@This());
}
