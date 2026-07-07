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
    try wm.output_list.append(allocator, output);
    wm.focused_output_idx = wm.output_list.items.len - 1;
    river_output.setListener(*types.WindowManager, outputListener, wm);
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
                    wm.focused_output_idx = null;
                    wm.previous_workspace = null;
                } else if (wm.focused_output_idx) |foi| {
                    if (foi >= active_count) {
                        wm.focused_output_idx = active_count - 1;
                    }
                }

                const previous_workspace = wm.previous_workspace orelse return;
                if (previous_workspace.output_idx == idx) {
                    wm.previous_workspace = null;
                } else if (previous_workspace.output_idx >= active_count and active_count > 0) {
                    wm.previous_workspace.?.output_idx = active_count - 1;
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
