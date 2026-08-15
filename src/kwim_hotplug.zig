const std = @import("std");
const Io = std.Io;

const wayland = @import("wayland");
const river = wayland.client.river;

const spawn = @import("spawn.zig");
const types = @import("types.zig");

pub fn inputManagerListener(
    _: *river.InputManagerV1,
    event: river.InputManagerV1.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .input_device => |data| {
            triggerHotplug(wm);
            data.id.destroy();
        },
        else => {},
    }
}

pub fn libinputConfigListener(
    _: *river.LibinputConfigV1,
    event: river.LibinputConfigV1.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .libinput_device => |data| {
            triggerHotplug(wm);
            data.id.destroy();
        },
        else => {},
    }
}

pub fn xkbConfigListener(
    _: *river.XkbConfigV1,
    event: river.XkbConfigV1.Event,
    wm: *types.WindowManager,
) void {
    switch (event) {
        .xkb_keyboard => |data| {
            triggerHotplug(wm);
            data.id.destroy();
        },
        else => {},
    }
}

pub fn triggerHotplug(wm: *types.WindowManager) void {
    if (wm.kwim_hotplug_pending) return;
    wm.kwim_hotplug_pending = true;

    const now = Io.Clock.awake.now(wm.io).toMilliseconds();
    wm.timer_queue.schedule(wm.allocator, 100, now, wm, runKwim) catch |err| {
        std.debug.print("Failed to schedule kwim hotplug: {}\n", .{err});
        wm.kwim_hotplug_pending = false;
    };
}

fn runKwim(wm: *types.WindowManager) void {
    wm.kwim_hotplug_pending = false;
    spawn.spawnDetached(wm.allocator, &.{"kwim"}, wm.environ_map);
}
