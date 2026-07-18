const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wayland = @import("wayland");
const river = wayland.client.river;
const wl = wayland.client.wl;

pub const actions = @import("actions.zig");
pub const Button = actions.Button;
pub const PointerAction = actions.PointerAction;
pub const KeybindingAction = actions.KeybindingAction;

/// Window pending initialization: held in pending_windows until
/// .dimensions arrives, then moved to a workspace.
pub const PendingWindow = struct {
    river_window: *river.WindowV1,
    initialized: bool = false,
    /// Owned copies of the latest app_id/title events, freed when the
    /// pending window is removed.
    title: ?[:0]const u8 = null,
    app_id: ?[:0]const u8 = null,
};

pub const WindowManager = struct {
    allocator: Allocator,
    io: Io,
    environ_map: std.process.Environ.Map,
    registry: *wayland.client.wl.Registry,
    river_window_manager: ?*river.WindowManagerV1,
    river_xkb_bindings: ?*river.XkbBindingsV1,
    river_layer_shell: ?*river.LayerShellV1,
    river_seat: ?*river.SeatV1,
    output_list: std.ArrayList(Output),
    focused_output_idx: ?usize,
    previous_workspace: ?struct { output_idx: usize, workspace_idx: usize },
    status: Status,
    config: *Config,
    pending_windows: std.ArrayList(PendingWindow) = .empty,
    xkb_binding_list: std.ArrayList(struct {
        river_xkb_binding: *river.XkbBindingV1,
        action: KeybindingAction,
    }),
    pointer_binding_list: std.ArrayList(struct {
        river_pointer_binding: *river.PointerBindingV1,
        action: PointerAction,
    }),
    /// Outputs detached while outputs were removed (e.g. laptop panel
    /// powered off during lock, TTY switch-away). Their workspaces and
    /// windows are preserved here so they can be restored when an output
    /// with the matching name reappears.
    detached_outputs: std.StringHashMap(DetachedOutput),
    overview_state: ?OverviewState = null,
    needs_refocus: bool = false,
    needs_setup_bindings: bool = false,
    should_exit_loop: bool = false,

    /// Last regular window we requested the compositor to focus. Used to
    /// avoid sending redundant focus/clear_focus requests, which break input
    /// method clients (fcitx5, kwim) on every layout cycle.
    last_focused_window: ?*river.WindowV1 = null,

    /// Current layer-shell focus state from river_layer_shell_seat_v1.
    layer_shell_focus: enum { none, non_exclusive, exclusive } = .none,

    /// True when the compositor has sent session_locked (ext-session-lock-v1).
    /// Keybindings are suppressed while locked.
    session_locked: bool = false,

    /// Window focused when the session was locked, restored on unlock.
    /// Follows KWM's save/restore pattern for swayidle -> waylock.
    /// We store the river_window pointer rather than indices so focus is
    /// restored correctly even if outputs are removed/re-added during lock.
    lock_focus: ?*river.WindowV1 = null,

    /// Set when the focused output changes because an output was added/removed;
    /// the next layout pass warps the pointer to the new output so the cursor
    /// follows focus, matching niri and hyprland behavior.
    needs_pointer_warp: bool = false,

    pub fn getConfig(self: *WindowManager) *const Config {
        return self.config;
    }

    pub fn currentWorkspace(self: *WindowManager) ?WorkspaceRef {
        const output_idx = self.focused_output_idx orelse return null;
        if (output_idx >= self.output_list.items.len) return null;
        const output = &self.output_list.items[output_idx];

        const workspace_idx = output.focused_workspace_idx;
        if (workspace_idx >= output.workspace_list.len) return null;
        const workspace = &output.workspace_list[workspace_idx];

        return .{
            .output_idx = output_idx,
            .workspace_idx = workspace_idx,
            .output = output,
            .workspace = workspace,
        };
    }

    pub fn currentFocus(self: *WindowManager) ?Focus {
        const ws = self.currentWorkspace() orelse return null;
        const window = ws.focusedWindow() orelse return null;

        return .{
            .output_idx = ws.output_idx,
            .workspace_idx = ws.workspace_idx,
            .window_idx = ws.workspace.focused_window_idx.?,
            .output = ws.output,
            .workspace = ws.workspace,
            .window = window,
        };
    }

    pub fn deinit(self: *WindowManager) void {
        // Destroy pending windows that were never assigned to a workspace.
        for (self.pending_windows.items) |pending| {
            if (self.river_window_manager != null) {
                pending.river_window.destroy();
            }
            if (pending.title) |t| self.allocator.free(t);
            if (pending.app_id) |a| self.allocator.free(a);
        }
        self.pending_windows.deinit(self.allocator);

        std.zon.parse.free(self.allocator, self.config);

        if (self.overview_state) |*state| state.origins.deinit(self.allocator);

        for (self.xkb_binding_list.items) |binding| {
            binding.river_xkb_binding.destroy();
        }
        self.xkb_binding_list.deinit(self.allocator);

        for (self.pointer_binding_list.items) |binding| {
            binding.river_pointer_binding.destroy();
        }
        self.pointer_binding_list.deinit(self.allocator);

        {
            var it = self.detached_outputs.iterator();
            while (it.next()) |kv| {
                self.allocator.free(kv.key_ptr.*);
                for (&kv.value_ptr.workspace_list) |*workspace| {
                    for (workspace.window_list.items) |*window| {
                        if (window.former_output_name) |name| self.allocator.free(name);
                    }
                    workspace.window_list.deinit(self.allocator);
                }
            }
        }
        self.detached_outputs.deinit();

        for (self.output_list.items) |*output| {
            for (&output.workspace_list) |*workspace| {
                for (workspace.window_list.items) |*window| {
                    if (window.former_output_name) |name| self.allocator.free(name);
                }
                workspace.window_list.deinit(self.allocator);
            }
            if (output.name) |name| self.allocator.free(name);
            if (output.wl_output) |wl_output| wl_output.destroy();
            if (output.river_layer_shell_output) |layer_shell_output| {
                layer_shell_output.destroy();
            }
            if (self.river_window_manager != null) {
                output.river_output.destroy();
            }
        }
        self.output_list.deinit(self.allocator);

        self.registry.destroy();
    }
};

pub const Window = struct {
    river_window: *river.WindowV1,
    river_node: *river.NodeV1,
    proportion: f32,
    is_fullscreen: bool,
    is_floating: bool = false,
    is_closing: bool,
    floating: Rectangle,
    current: Rectangle,
    start: ?Rectangle,
    finish: ?Rectangle,
    /// Last geometry sent to the compositor; used to skip redundant requests.
    sent_current: ?Rectangle = null,
    sent_clip: ?Rectangle = null,
    sent_visible: ?bool = null,
    /// Last border focus state sent to the compositor.
    sent_border_focused: ?bool = null,
    /// Last border width sent to the compositor.
    sent_border_width: ?u8 = null,
    /// Name of the output this window was migrated from (if any). Used to
    /// return windows to their original output when it reappears.
    former_output_name: ?[]const u8 = null,
};

pub const Layout = enum { scroller, floating };

pub const WorkspaceRef = struct {
    output_idx: usize,
    workspace_idx: usize,
    output: *Output,
    workspace: *Workspace,

    pub fn focusedWindow(self: WorkspaceRef) ?*Window {
        const window_idx = self.workspace.focused_window_idx orelse return null;
        if (window_idx >= self.workspace.window_list.items.len) return null;
        return &self.workspace.window_list.items[window_idx];
    }

    pub fn focusedWindowWithIdx(self: WorkspaceRef) ?struct { idx: usize, window: *Window } {
        const window_idx = self.workspace.focused_window_idx orelse return null;
        if (window_idx >= self.workspace.window_list.items.len) return null;
        return .{ .idx = window_idx, .window = &self.workspace.window_list.items[window_idx] };
    }
};

pub const Focus = struct {
    output_idx: usize,
    workspace_idx: usize,
    window_idx: usize,
    output: *Output,
    workspace: *Workspace,
    window: *Window,
};

pub const Workspace = struct {
    window_list: std.ArrayList(Window) = .empty,
    focused_window_idx: ?usize = null,
    is_floating: bool = false,
    layout: Layout = .scroller,
};

pub const Output = struct {
    river_output: *river.OutputV1,
    river_layer_shell_output: ?*river.LayerShellOutputV1,
    wl_output: ?*wl.Output = null,
    name: ?[]const u8 = null,
    workspace_list: [10]Workspace,
    focused_workspace_idx: usize,
    rectangle: Rectangle,
    non_exclusive: Rectangle,
    is_removed: bool,
    /// True when this output has windows that need per-frame animation.
    is_animating: bool = false,
};

/// A detached output, used when an output is removed. The workspaces and
/// their windows are preserved here so they can be restored to an output
/// with the same name when it reappears, without losing the river_window_v1
/// proxies.
pub const DetachedOutput = struct {
    workspace_list: [10]Workspace,
    focused_workspace_idx: usize,
};

pub const Rectangle = struct {
    width: i32,
    height: i32,
    x: i32,
    y: i32,

    pub fn eql(self: Rectangle, other: Rectangle) bool {
        return self.x == other.x and
            self.y == other.y and
            self.width == other.width and
            self.height == other.height;
    }
};

pub const Status = union(enum) {
    layout: void,
    animation: i64,
    pointer_action: PointerAction,
    overview: void,
    setup_bindings: void,
    exit: void,
    none: void,
};

pub const OverviewState = struct {
    /// Maps each overview grid slot to its original (output_idx, workspace_idx, window_idx).
    origins: std.ArrayList(Origin),
    highlighted: usize,
    columns: usize,
    output_idx: usize,
    previous_workspace: ?struct { output_idx: usize, workspace_idx: usize },

    pub const Origin = struct {
        output_idx: usize,
        workspace_idx: usize,
        window_idx: usize,
    };
};

pub const Config = struct {
    vertical_gap: i32 = 9,
    horizontal_gap: i32 = 9,
    default_window_width: f32 = 0.5,
    center_focused_window: enum { never, always, single } = .never,
    no_csd: bool = true,
    animation_duration: u32 = 200,
    border: Border = .{
        .width = 3,
        .focused_color = .{ .r = 141, .g = 214, .b = 0, .a = 1.0 },
        .unfocused_color = .{ .r = 160, .g = 160, .b = 160, .a = 1.0 },
    },
    cursor: ?struct { theme: [:0]const u8, size: u32 } = null,
    spawn_at_startup: []const []const []const u8 = &.{},
    keybindings: []const Keybinding = &.{},
    pointer_bindings: []const PointerBinding = &.{},
    window_rules: []const WindowRule = &.{},
};

/// Rule matching windows by exact app_id/title. All set fields must match.
pub const WindowRule = struct {
    app_id: ?[:0]const u8 = null,
    title: ?[:0]const u8 = null,
    floating: bool = false,

    pub fn matches(rule: WindowRule, app_id: ?[:0]const u8, title: ?[:0]const u8) bool {
        if (rule.app_id == null and rule.title == null) return false;
        if (rule.app_id) |a| {
            if (app_id == null or !std.mem.eql(u8, a, app_id.?)) return false;
        }
        if (rule.title) |t| {
            if (title == null or !std.mem.eql(u8, t, title.?)) return false;
        }
        return true;
    }
};

test "WindowRule.matches" {
    const r: WindowRule = .{ .app_id = "footclient", .floating = true };
    try std.testing.expect(r.matches("footclient", null));
    try std.testing.expect(!r.matches("foot", null));
    try std.testing.expect(!r.matches(null, null));
    const both: WindowRule = .{ .app_id = "a", .title = "t" };
    try std.testing.expect(both.matches("a", "t"));
    try std.testing.expect(!both.matches("a", "x"));
    const empty: WindowRule = .{ .floating = true };
    try std.testing.expect(!empty.matches("a", "t"));
}

const Border = struct { width: u8, focused_color: Color, unfocused_color: Color };

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: f32,
};

pub const Keybinding = struct {
    key: [:0]const u8,
    modifiers: river.SeatV1.Modifiers,
    action: KeybindingAction,
};

pub const PointerBinding = struct {
    button: Button,
    modifiers: river.SeatV1.Modifiers,
    action: PointerAction,
};
