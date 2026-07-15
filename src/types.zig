const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const wayland = @import("wayland");
const river = wayland.client.river;

pub const actions = @import("actions.zig");
pub const Button = actions.Button;
pub const PointerAction = actions.PointerAction;
pub const KeybindingAction = actions.KeybindingAction;

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
    xkb_binding_list: std.ArrayList(struct {
        river_xkb_binding: *river.XkbBindingV1,
        action: KeybindingAction,
    }),
    pointer_binding_list: std.ArrayList(struct {
        river_pointer_binding: *river.PointerBindingV1,
        action: PointerAction,
    }),
    /// Workspaces saved when the last output is removed. River keeps the
    /// underlying river_window_v1 proxies alive, so we restore these windows
    /// when a replacement output appears (e.g. TTY switch-back).
    detached_workspaces: ?[10]Workspace,
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

        if (self.detached_workspaces) |*detached| {
            for (detached) |*workspace| {
                workspace.window_list.deinit(self.allocator);
            }
        }

        for (self.output_list.items) |*output| {
            for (&output.workspace_list) |*workspace| {
                workspace.window_list.deinit(self.allocator);
            }
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
    workspace_list: [10]Workspace,
    focused_workspace_idx: usize,
    rectangle: Rectangle,
    non_exclusive: Rectangle,
    is_removed: bool,
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
    /// Maps each overview grid slot to its original (workspace_idx, window_idx).
    origins: std.ArrayList(Origin),
    highlighted: usize,
    columns: usize,
    output_idx: usize,
    previous_workspace: ?struct { output_idx: usize, workspace_idx: usize },

    pub const Origin = struct {
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
    keybindings: []const Keybinding = &default_keybindings,
    pointer_bindings: []const PointerBinding = &default_pointer_bindings,
};

const Border = struct { width: u8, focused_color: Color, unfocused_color: Color };

const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: f32,

    pub fn toRiverColor(self: Color) struct { r: u32, g: u32, b: u32, a: u32 } {
        var r: f32 = @floatFromInt(self.r);
        var g: f32 = @floatFromInt(self.g);
        var b: f32 = @floatFromInt(self.b);

        r = self.a * r / 255;
        g = self.a * g / 255;
        b = self.a * b / 255;

        const max: f64 = @floatFromInt(std.math.maxInt(u32));
        return .{
            .r = @trunc(r * max),
            .g = @trunc(g * max),
            .b = @trunc(b * max),
            .a = @trunc(self.a * max),
        };
    }
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

pub const default_keybindings = [_]Keybinding{
    .{ .key = "q", .modifiers = .{ .mod4 = true }, .action = .close_window },
    .{ .key = "f", .modifiers = .{ .mod4 = true }, .action = .toggle_fullscreen },

    .{ .key = "minus", .modifiers = .{ .mod4 = true }, .action = .{ .adjust_window_width = -0.1 } },
    .{ .key = "equal", .modifiers = .{ .mod4 = true }, .action = .{ .adjust_window_width = 0.1 } },
    .{ .key = "BackSpace", .modifiers = .{ .mod4 = true }, .action = .{ .set_window_width = 0.5 } },

    .{ .key = "Left", .modifiers = .{ .mod4 = true }, .action = .focus_window_left },
    .{ .key = "Right", .modifiers = .{ .mod4 = true }, .action = .focus_window_right },
    .{ .key = "Left", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_left },
    .{ .key = "Right", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_right },

    .{ .key = "v", .modifiers = .{ .mod4 = true }, .action = .toggle_workspace_floating },

    .{ .key = "Up", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_above },
    .{ .key = "Down", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_below },
    .{ .key = "grave", .modifiers = .{ .mod4 = true }, .action = .focus_workspace_previous },

    .{ .key = "1", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 1 } },
    .{ .key = "2", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 2 } },
    .{ .key = "3", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 3 } },
    .{ .key = "4", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 4 } },
    .{ .key = "5", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 5 } },
    .{ .key = "6", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 6 } },
    .{ .key = "7", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 7 } },
    .{ .key = "8", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 8 } },
    .{ .key = "9", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 9 } },
    .{ .key = "0", .modifiers = .{ .mod4 = true }, .action = .{ .focus_workspace_number = 10 } },

    .{ .key = "Up", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_workspace_above },
    .{ .key = "Down", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_workspace_below },

    .{ .key = "1", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 1 } },
    .{ .key = "2", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 2 } },
    .{ .key = "3", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 3 } },
    .{ .key = "4", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 4 } },
    .{ .key = "5", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 5 } },
    .{ .key = "6", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 6 } },
    .{ .key = "7", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 7 } },
    .{ .key = "8", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 8 } },
    .{ .key = "9", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 9 } },
    .{ .key = "0", .modifiers = .{ .mod4 = true, .shift = true }, .action = .{ .move_window_to_workspace_number = 10 } },

    .{ .key = "h", .modifiers = .{ .mod4 = true }, .action = .focus_output_left },
    .{ .key = "l", .modifiers = .{ .mod4 = true }, .action = .focus_output_right },
    .{ .key = "k", .modifiers = .{ .mod4 = true }, .action = .focus_output_above },
    .{ .key = "j", .modifiers = .{ .mod4 = true }, .action = .focus_output_below },

    .{ .key = "h", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_left },
    .{ .key = "l", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_right },
    .{ .key = "k", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_above },
    .{ .key = "j", .modifiers = .{ .mod4 = true, .shift = true }, .action = .move_window_to_output_below },

    .{ .key = "Escape", .modifiers = .{ .mod4 = true }, .action = .exit },
    .{ .key = "r", .modifiers = .{ .mod4 = true }, .action = .reload_config },

    .{ .key = "t", .modifiers = .{ .mod4 = true }, .action = .{ .spawn = &[_][]const u8{"alacritty"} } },
    .{ .key = "Space", .modifiers = .{ .mod4 = true }, .action = .enter_overview },

    .{
        .key = "XF86AudioRaiseVolume",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.05+", "--limit", "1.0" } },
    },
    .{
        .key = "XF86AudioLowerVolume",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.05-" } },
    },
    .{
        .key = "XF86AudioMute",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" } },
    },
    .{
        .key = "XF86AudioMicMute",
        .modifiers = .{},
        .action = .{ .spawn = &[_][]const u8{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle" } },
    },
};

const default_pointer_bindings = [_]PointerBinding{
    .{ .button = .left, .modifiers = .{ .mod4 = true }, .action = .move_window },
    .{ .button = .right, .modifiers = .{ .mod4 = true }, .action = .resize_window },
};

